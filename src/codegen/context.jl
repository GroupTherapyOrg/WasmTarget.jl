# ============================================================================
# Compilation Context
# ============================================================================

"""
Abstract supertype for compilation contexts.
CompilationContext is the sole function-compilation context.
"""
abstract type AbstractCompilationContext end

"""
Tracks state during compilation of a single function.
"""
mutable struct CompilationContext <: AbstractCompilationContext
    arg_types::Tuple
    return_type::Type
    n_params::Int
    locals::Vector{WasmValType}  # Additional locals beyond params (supports refs)
    ssa_types::IntKeyMap{Type}   # SSA value -> Julia type
    ssa_locals::IntKeyMap{Int}   # SSA value -> local index (for multi-use SSAs)
    phi_locals::IntKeyMap{Int}   # PhiNode SSA -> local index
    loop_headers::Vector{Bool}   # Line numbers that are loop headers (bitmap)
    mod::WasmModule              # The module being built
    type_registry::TypeRegistry  # Struct type mappings
    func_registry::Union{FunctionRegistry, Nothing}  # Function mappings for cross-calls
    func_idx::UInt32             # Index of the function being compiled (for recursion)
    func_ref::Any                # Reference to original function (for self-call detection)
    global_args::Set{Int}        # Argument indices (1-based) that are WasmGlobal (phantom params)
    is_compiled_closure::Bool    # True if function being compiled is itself a closure
    # Signal substitution for Therapy.jl closures
    signal_ssa_getters::Dict{Int, UInt32}   # SSA id (from getfield) -> Wasm global index
    signal_ssa_setters::Dict{Int, UInt32}   # SSA id (from getfield) -> Wasm global index
    captured_signal_fields::Dict{Symbol, Tuple{Bool, UInt32}}  # field_name -> (is_getter, global_idx)
    captured_constant_fields::Dict{Symbol, Any} # exact closure values substituted at the root
    # DOM bindings for Therapy.jl - emit DOM update calls after signal writes
    # Maps global_idx -> [(import_idx, [hk_arg, ...]), ...]
    dom_bindings::Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}
    # Scratch local indices for string operations (fixed at allocation time)
    # Tuple of (result_local, str1_local, str2_local, len1_local, i_local) or nothing
    scratch_locals::Union{Nothing, NTuple{5, Int}}
    # Central convertType boxing reuses one scratch local per physical numeric
    # representation; scratch lifetime ends at each synchronous box emission.
    boxing_scratch_locals::Dict{WasmValType, Int}
    # The i32 element-offset local of each MemoryRef phi that carries one; the phi's
    # memory rides its phi local (allocate_memoryref_offset_locals!, builtins.jl).
    memoryref_offset_locals::Dict{Int, Int}
    # Set true by compile_call/compile_invoke when a stub emits UNREACHABLE.
    # compile_statement reads and resets this to skip LOCAL_SET in dead code.
    last_stmt_was_stub::Bool
    # The SSA statement being compiled (set by compile_statement!), so every
    # diagnostic — including ones raised deep inside helpers that carry no idx —
    # is attributed to a statement and its inline chain (dart's located reporter).
    current_stmt_idx::Int
    # Slot variable locals for unoptimized IR (may_optimize=false).
    # Maps SlotNumber.id -> WASM local index. Slot 1 = self, Slot 2 = arg1, etc.
    # Slots > n_params+1 are local variables assigned with Expr(:(=), SlotNumber, rhs).
    slot_locals::Dict{Int, Int}
    # Tier 2 hash dispatch tables for megamorphic calls
    dispatch_registry::Union{Nothing, DispatchTableRegistry}
    # Scratch i32 local for typeof struct lookup (cached)
    typeof_scratch_local::Union{Nothing, UInt32}
    # Skip statements: IR indices that should emit NOP instead of UNREACHABLE.
    # Used by Therapy.jl to skip js() calls that are handled externally in JS.
    skip_stmts::Set{Int}
    # Invoke imports: IR indices that should emit CALL to a specific import function
    # instead of normal compilation. Maps SSA index -> WASM import function index.
    # Used by Therapy.jl to wire js() calls as WASM imports (Leptos pattern).
    invoke_imports::Dict{Int, UInt32}
    invoke_arguments::Dict{Int, Vector{Int}} # explicit source-argument projection per bound invoke
    entry_calls::Vector{UInt32} # typed zero-argument runtime adapters before root body
    # Diagnostics accumulated during compilation (see diagnostics.jl).
    diagnostics::Vector{WasmDiagnostic}
    # Per-try-region exception payload locals (dart binds each catch's
    # exception to its OWN local; keyed by the region's enter_idx). :the_exception
    # reads the ENCLOSING region's local; $current_exn dies when all reads are local.
    exn_region_locals::Dict{Int, Int}
    # NIR boundary (parity: code_generator.dart:77 typeContext) — frontend/nir.jl's
    # build_nir output, one record per IR statement. Built FIRST, from the typed IR alone,
    # so the analysis passes below are themselves NIR consumers rather than its
    # prerequisites; the context reads Julia's IR through it and nothing else.
    nir::Vector{NirStmt}
    # Julia inference's type for every IR slot, widened once at the boundary
    # (frontend/nir.jl's nir_slot_types) — what an Argument/SlotNumber operand is typed by.
    slot_types::Vector{Type}
    # The function's source-location table: a located diagnostic decodes a statement's
    # inline chain and the method's definition site from it (diagnostics.jl).
    debuginfo::Union{Core.DebugInfo, Nothing}
end

function CompilationContext(body::NirBody, arg_types::Tuple, return_type, mod::WasmModule, type_registry::TypeRegistry;
                           func_registry::Union{FunctionRegistry, Nothing}=nothing,
                           func_idx::UInt32=UInt32(0), func_ref=nothing,
                           global_args::Set{Int}=Set{Int}(),
                           is_compiled_closure::Bool=false,
                           captured_signal_fields::Dict{Symbol, Tuple{Bool, UInt32}}=Dict{Symbol, Tuple{Bool, UInt32}}(),
                           captured_constant_fields::Dict{Symbol, Any}=Dict{Symbol, Any}(),
                           dom_bindings::Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}=Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}(),
                           dispatch_registry::Union{Nothing, DispatchTableRegistry}=nothing,
                           skip_stmts::Set{Int}=Set{Int}(),
                           invoke_imports::Dict{Int, UInt32}=Dict{Int, UInt32}())
    # Calculate n_params excluding WasmGlobal arguments (they're phantom)
    n_real_params = count(i -> !(i in global_args), 1:length(arg_types))
    n_stmts = length(body.stmts)
    ctx = CompilationContext(
        arg_types,
        return_type,
        n_real_params,
        WasmValType[],
        IntKeyMap{Type}(n_stmts),
        IntKeyMap{Int}(n_stmts),
        IntKeyMap{Int}(n_stmts),
        fill(false, n_stmts),
        mod,
        type_registry,
        func_registry,
        func_idx,
        func_ref,
        global_args,
        is_compiled_closure,    # Is this function itself a closure?
        Dict{Int, UInt32}(),    # signal_ssa_getters
        Dict{Int, UInt32}(),    # signal_ssa_setters
        captured_signal_fields, # captured signal field mappings
        captured_constant_fields, # exact captured constant mappings
        dom_bindings,           # DOM bindings for Therapy.jl
        nothing,                # scratch_locals (set by allocate_scratch_locals!)
        Dict{WasmValType, Int}(), # boxing_scratch_locals
        Dict{Int, Int}(),       # memoryref_offset_locals (allocate_memoryref_offset_locals!)
        false,                  # last_stmt_was_stub 
        0,                      # current_stmt_idx
        Dict{Int, Int}(),       # slot_locals (unoptimized IR slot variables)
        dispatch_registry,      # Tier 2 hash dispatch
        nothing,                # typeof scratch local (allocated on demand)
        skip_stmts,             # Skip statements (Therapy.jl js() interop)
        invoke_imports,         # Invoke imports (Therapy.jl js() as WASM imports)
        Dict{Int,Vector{Int}}(), # bound-invoke argument projections (assigned by plan)
        UInt32[],                # root entry calls (assigned by the closed-world plan)
        WasmDiagnostic[],        # Diagnostics accumulated during compilation
        Dict{Int, Int}(),       # exn_region_locals
        body.stmts,             # NIR boundary — built first, from the typed IR alone
        body.slot_types,
        body.debuginfo
    )
    # Analyze SSA types and allocate locals for multi-use SSAs. These passes run before
    # any statement is compiled, so a failure inside them is attributed to the FUNCTION
    # (the statement entry, L119, cannot see it) — never a bare error naming no site.
    try
        analyze_ssa_types!(ctx)
        analyze_control_flow!(ctx)  # Find loops and phi nodes
        analyze_signal_captures!(ctx)  # Identify SSAs that are signal getters/setters
        allocate_slot_locals!(ctx)  # Slot locals BEFORE SSA locals (no overlap)
        allocate_ssa_locals!(ctx)
        allocate_memoryref_offset_locals!(ctx)
        allocate_scratch_locals!(ctx)  # Extra locals for complex operations
    catch e
        (e isa WasmCompileError || e isa WasmInternalError) && rethrow()
        throw(WasmInternalError(_ctx_func_name(ctx), 0, "", String[], e))
    end
    return ctx
end

"""
Analyze getfield expressions on the closure (arg 1) to identify signal captures.
Maps SSA values from getfield to their signal global indices.

For CompilableSignal/CompilableSetter pattern:
- getfield(_1, :count) -> CompilableSignal SSA
- getfield(CompilableSignal, :signal) -> Signal SSA
- getfield(Signal, :value) -> actual value read (substitutes to global.get)
- setfield!(Signal, :value, x) -> value write (substitutes to global.set)
"""
function analyze_signal_captures!(ctx::AbstractCompilationContext)
    isempty(ctx.captured_signal_fields) && return

    nir = ctx.nir
    # `getfield(target, field)` / `setfield!(target, field, value)` statements — the
    # target operand and the field literal (or its operand when it is not a literal)
    _field_access(rec, f, nops) = begin
        local node = rec.node
        if rec.slot == 0 && node isa NirCall && node.callee === f && length(node.operands) >= nops
            local fld = node.operands[2]
            (node.operands[1], fld isa NirLiteral ? fld.value : fld)
        else
            nothing
        end
    end
    # getfield(_1, :fieldname) — a captured closure field (slot 1 or argument 1)
    _is_closure_self(t) = (t isa NirSlot && t.id == 1) || (t isa NirArgument && t.n == 1)

    # For Therapy.jl: captured signal fields are getter/setter FUNCTIONS (closures)
    # When we see getfield(_1, :count) where :count is a getter, the resulting SSA
    # is a function that when invoked returns the signal value.
    # We directly map these to signal_ssa_getters/setters so that when compile_invoke
    # sees invoke(%ssa), it knows to emit global.get/global.set.

    # First pass: find closure field accesses to signal getter/setter functions
    for (i, rec) in enumerate(nir)
        access = _field_access(rec, Core.getfield, 2)
        access === nothing && continue
        target, field_name = access
        if _is_closure_self(target) && field_name isa Symbol &&
           haskey(ctx.captured_signal_fields, field_name)
            is_getter, global_idx = ctx.captured_signal_fields[field_name]
            # Directly map the SSA to signal getter/setter
            # When this SSA is invoked, it becomes a signal read or write
            if is_getter
                ctx.signal_ssa_getters[i] = global_idx
            else
                ctx.signal_ssa_setters[i] = global_idx
            end
        end
    end

    # Also handle WasmGlobal-style patterns (for compatibility with WasmGlobal{T, IDX})
    # Track CompilableSignal/CompilableSetter SSAs
    compilable_ssas = Dict{Int, Tuple{Bool, UInt32}}()  # ssa -> (is_getter, global_idx)

    # Track Signal SSAs (from getfield(CompilableSignal/Setter, :signal))
    signal_ssas = Dict{Int, UInt32}()  # ssa -> global_idx

    # Find getfield(_1, :fieldname) that might be WasmGlobal-style
    for (i, rec) in enumerate(nir)
        access = _field_access(rec, Core.getfield, 2)
        access === nothing && continue
        target, field_name = access
        if _is_closure_self(target) && field_name isa Symbol &&
           haskey(ctx.captured_signal_fields, field_name)
            compilable_ssas[i] = ctx.captured_signal_fields[field_name]
        end
    end

    # Find getfield(CompilableSignal/Setter, :signal) -> Signal
    for (i, rec) in enumerate(nir)
        access = _field_access(rec, Core.getfield, 2)
        access === nothing && continue
        target, field_name = access
        if target isa NirSSA && field_name === :signal && haskey(compilable_ssas, target.id)
            _, global_idx = compilable_ssas[target.id]
            signal_ssas[i] = global_idx
        end
    end

    # Mark getfield(Signal, :value) as signal reads
    # and setfield!(Signal, :value, x) as signal writes
    for (i, rec) in enumerate(nir)
        read = _field_access(rec, Core.getfield, 2)
        if read !== nothing
            target, field_name = read
            if target isa NirSSA && field_name === :value && haskey(signal_ssas, target.id)
                ctx.signal_ssa_getters[i] = signal_ssas[target.id]
            end
        end
        write = _field_access(rec, Core.setfield!, 3)
        if write !== nothing
            target, field_name = write
            if target isa NirSSA && field_name === :value && haskey(signal_ssas, target.id)
                ctx.signal_ssa_setters[i] = signal_ssas[target.id]
            end
        end
    end
end

"""
Allocate scratch locals for complex operations like string concatenation.
These are extra locals beyond what SSA analysis requires.
Stores the indices in ctx.scratch_locals for later use.
"""
function allocate_scratch_locals!(ctx::AbstractCompilationContext)
    # Check if any SSA type is String or Symbol - if so, we need scratch locals
    # Symbol uses same array<i32> representation as String and needs element-wise comparison
    needs_string_scratch = false
    for (_, T) in ctx.ssa_types
        if T === String || T === Symbol
            needs_string_scratch = true
            break
        end
    end

    # Also check if return type or arg types include String/Symbol
    if ctx.return_type === String || ctx.return_type === Symbol
        needs_string_scratch = true
    end
    for T in ctx.arg_types
        if T === String || T === Symbol
            needs_string_scratch = true
            break
        end
    end

    if needs_string_scratch
        # Add 5 scratch locals for string operations:
        # - 1 ref for result array
        # - 2 refs for source strings
        # - 2 i32s for lengths/indices
        # Use get_string_array_type! to ensure type is registered
        str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        str_ref_type = ConcreteRef(str_type_idx, true)

        # Calculate indices BEFORE adding locals (indices are n_params + current local count)
        scratch_base = ctx.n_params + length(ctx.locals)
        result_local = scratch_base      # ref for result
        str1_local = scratch_base + 1    # ref for str1
        str2_local = scratch_base + 2    # ref for str2
        len1_local = scratch_base + 3    # i32 for len1
        i_local = scratch_base + 4       # i32 for len2/index

        # Store the indices in context
        ctx.scratch_locals = (result_local, str1_local, str2_local, len1_local, i_local)

        # Now add the locals
        push!(ctx.locals, str_ref_type)  # result/scratch ref 1
        push!(ctx.locals, str_ref_type)  # scratch ref 2
        push!(ctx.locals, str_ref_type)  # scratch ref 3
        push!(ctx.locals, I32)           # scratch i32 1 (len1)
        push!(ctx.locals, I32)           # scratch i32 2 (len2/i)
    end
end

"""
    allocate_local!(ctx, julia_type) -> local_index

Allocate a new local variable of the given Julia type and return its index.
The index is relative to the function's locals, accounting for parameters.
"""
function allocate_local!(ctx::AbstractCompilationContext, T::Type)::Int
    wasm_type = get_concrete_wasm_type(T, ctx.mod, ctx.type_registry; for_local=true)
    local_idx = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, wasm_type)
    return local_idx
end

function allocate_local!(ctx::AbstractCompilationContext, wasm_type::WasmValType)::Int
    local_idx = ctx.n_params + length(ctx.locals)
    # normalize AnyRef → ExternRef to avoid type hierarchy mismatches
    # Exception — keep AnyRef when $JlType hierarchy is active
    local actual_type = wasm_type
    if wasm_type === AnyRef && ctx.type_registry.jl_type_idx === nothing
        actual_type = ExternRef
    end
    push!(ctx.locals, actual_type)
    return local_idx
end

function boxing_scratch_local!(ctx::AbstractCompilationContext,
                               wasm_type::WasmValType)::Int
    get!(ctx.boxing_scratch_locals, wasm_type) do
        allocate_local!(ctx, wasm_type)
    end
end

"""
Convert a numeric value on the stack to f64 (no-op when already f64) — builder-native
(THE implementation). Used for DOM bindings where numerics pass as f64 for JS.
"""
function emit_convert_to_f64!(b, valtype::WasmValType)
    if valtype == I32
        num!(b, 0xB7)  # f64.convert_i32_s
    elseif valtype == I64
        num!(b, 0xB9)  # f64.convert_i64_s
    elseif valtype == F32
        num!(b, 0xBB)  # f64.promote_f32
    end
    return b
end

"""
Encode a block result type (for if/block/loop).
Handles both simple types (i32/i64/f32/f64) and concrete reference types.
Returns a vector of bytes to append to the instruction stream.
MULTI-VALUE blocktype — a function-type INDEX encoded as s33
(wasm spec). Used by the typed-catch landing block (results = the tag payload).
Int specifically (not Integer): UInt8 0x40/void keeps its raw single-byte path.
"""
encode_block_type(type_idx::Int)::Vector{UInt8} = encode_leb128_signed(Int64(type_idx))

function encode_block_type(result_type::WasmValType)::Vector{UInt8}
    bytes = UInt8[]
    if result_type isa NumType
        push!(bytes, UInt8(result_type))
    elseif result_type isa RefType
        push!(bytes, UInt8(result_type))
    elseif result_type isa ConcreteRef
        # Concrete reference type: 0x63 (nullable) or 0x64 (non-nullable) + type index
        if result_type.nullable
            push!(bytes, 0x63)  # ref null
        else
            push!(bytes, 0x64)  # ref
        end
        # Type index as signed LEB128
        append!(bytes, encode_leb128_signed(Int64(result_type.type_idx)))
    elseif result_type isa UInt8
        push!(bytes, result_type)
    else
        # Fallback - try to convert to UInt8
        push!(bytes, UInt8(result_type))
    end
    return bytes
end

# parity(code_generator.dart:3170 CodeGenerator.visitAsExpression): a CAST carries its target type — dart's `as T`
# (code_generator.dart:3170 visitAsExpression: a statically-satisfied cast —
# `omitExplicitTypeChecks || node.isUnchecked` — is EXACTLY `wrap(operand,
# expectedType)`: the operand through the one wrap channel, typed by the target).
# `convert(T, x)` / `typeassert(x, T)` results that inference left erased refine
# to T when the join already proves x carries exactly T (the identity cast the
# calls.jl arm lowers value-only, = dart's isUnchecked path) — the result local
# then types as T, so the store and every load agree (the escaping-closure
# i64-into-anyref invalid store). A genuinely-dynamic cast stays a loud reject
# (correct-or-loud) until dart's emitAsCheck analog lands.
function refine_checked_cast_types!(ctx::AbstractCompilationContext)
    # a constant operand's value: a bound global's, or the literal's
    _cres(a) = a isa NirGlobalRef ? (a.bound ? a.value : nothing) :
               a isa NirLiteral ? a.value : a
    for (_ck, _rec) in enumerate(ctx.nir)
        local _cnode = _rec.node
        (_rec.slot == 0 && (_cnode isa NirCall || _cnode isa NirInvoke)) || continue
        local _cargs = _cnode.operands
        length(_cargs) == 2 || continue
        local _cf = _nir_callee_object(_cnode.callee)
        local _isconv = _cf === Base.convert
        local _ista = _cf === Core.typeassert
        (_isconv || _ista) || continue
        local _cT = _cres(_cargs[_isconv ? 1 : 2])
        _cT isa DataType || continue
        local _cx = _cargs[_isconv ? 2 : 1]
        _cx isa NirSSA || continue
        local _corig = get(ctx.ssa_types, _ck, Any)
        (_corig === Any || _corig isa Union) || continue
        get(ctx.ssa_types, _cx.id, Any) === _cT || continue
        ctx.ssa_types[_ck] = _cT
    end
    return nothing
end

# The intrinsics whose operands a local's Wasm type must match numerically — a phi or an
# SSA local that inference typed as a reference but that feeds one of these is typed by the
# operand the intrinsic takes (boolean ops: i32; comparisons/arithmetic: the value's width).
# parity(quarantine: Julia's Core.Intrinsics — Kernel has no intrinsic-function operands.)
const _BOOL_OP_INTRINSICS = (:not_int, :and_int, :or_int, :xor_int)
# parity(quarantine: Julia's Core.Intrinsics comparison family.)
const _CMP_OP_INTRINSICS = (:eq_int, :ne_int, :slt_int, :sle_int, :ult_int, :ule_int)
# parity(quarantine: Julia's Core.Intrinsics arithmetic/conversion family.)
const _NUMERIC_OP_INTRINSICS = (:add_int, :sub_int, :mul_int, :sdiv_int, :udiv_int,
                                :srem_int, :urem_int, :neg_int,
                                :add_float, :sub_float, :mul_float, :div_float,
                                :neg_float, :abs_float, :sqrt_llvm,
                                :shl_int, :lshr_int, :ashr_int,
                                :checked_sadd_int, :checked_ssub_int, :checked_smul_int,
                                :checked_uadd_int, :checked_usub_int, :checked_umul_int,
                                :sitofp, :uitofp, :fptosi, :fptoui,
                                :trunc_int, :sext_int, :zext_int, :fpext, :fptrunc,
                                :ctpop_int, :ctlz_int, :cttz_int, :bswap_int,
                                :flipsign_int, :copysign_float,
                                :eq_float, :ne_float, :lt_float, :le_float)

# A field read: `getfield` itself, or a `getproperty` (Base's, or the Compiler's own), which
# Julia lowers a field read through.
# parity(quarantine: Julia's getproperty → getfield lowering — Kernel's InstanceGet is one node.)
_is_getfield_callee(@nospecialize(f))::Bool =
    f === Core.getfield || f === Base.getproperty || f === Core.Compiler.getproperty

"""
Analyze control flow to find loops and handle phi nodes.
"""
function analyze_control_flow!(ctx::AbstractCompilationContext)
    nir = ctx.nir

    # Find loop headers (targets of backward jumps — an unconditional goto back)
    for (i, rec) in enumerate(nir)
        if rec.node isa NirGoto && rec.node.target < i
            ctx.loop_headers[rec.node.target] = true
        end
    end

    # parity(translator.dart:2100 Translator.translateTypeOfLocalVariable): the Any-but-really-numeric JOIN (dart translateTypeOfLocalVariable —
    # a variable's local is typed by its REAL inferred type, not the erased Any). The
    # dormant Loop-C value-channel pass proves, conservatively, which Any-typed SSAs/phis
    # only ever carry one numeric type (the scalar-replaced Core.Box accumulator cycle);
    # their locals become that numeric type so the adds/stores line up — the return/phi
    # boundaries box via the wrap channel where anyref is genuinely required.
    _numeric_joins = try
        # Parent side: record %new(Core.Box) contents types per capturing closure type
        # (feeds the closure-side seeding below when THAT closure's body compiles).
        populate_box_field_types!(ctx.mod, ctx.type_registry, ctx.nir, ctx.ssa_types)
        _joins = propagate_numeric_value_types(ctx.nir, ctx.ssa_types;
            argtypes=ctx.arg_types, self_shift=(ctx.is_compiled_closure ? 0 : 1))
        # Closure side: seed the captured-Box getfields with the recorded contents type
        # (dart translateTypeOfLocalVariable for captures), then propagate through the body.
        # Closure-LOCAL typed capture: solve the self-captured Box contents type from the
        # body alone (optimistic + verified) — covers the parent-scalar-replaced case.
        _sbT = ctx.func_ref isa DataType ? ctx.func_ref : typeof(ctx.func_ref)
        if _sbT isa DataType && isstructtype(_sbT)
            _sst = ctx.nir   # Julia inference's own SSA types (the NIR boundary's widened answer)
            _conservative_joins = copy(_joins)   # propagate output only (proven cycles)
            merge!(_joins, f3_self_box_joins(ctx.nir, _sst, _sbT;
                argtypes=ctx.arg_types, self_shift=1))
        end
        if _sbT isa DataType && ctx.type_registry.box_contents_types !== nothing
            _selfT = _sbT
            _bw = get(ctx.type_registry.box_contents_types, _selfT, nothing)
            _bj = _bw === I64 ? Int64 : _bw === I32 ? Int32 :
                  _bw === F64 ? Float64 : _bw === F32 ? Float32 : nothing
            if _bj !== nothing
                _seeds = f3_closure_box_seeds(ctx.nir, _selfT, _bj)
                if !isempty(_seeds)
                    merge!(_joins, f3_box_value_types(ctx.nir, ctx.ssa_types; extra_box_seeds=_seeds))
                    merge!(_joins, _seeds)
                end
            end
        end
        _joins
    catch
        rethrow()
    end
    # parity(translator.dart:2100 Translator.translateTypeOfLocalVariable): the join IS the variable's real type (dart translateTypeOfLocalVariable)
    # — visible to EVERY consumer, not just local allocation. Without this, compile_call
    # still saw `Any`, classified the accumulator `+` as dynamic, and emitted the
    # type-safe-default ZERO (the mutable-capture silent 0).
    # ONLY the CONSERVATIVE joins (the fixed-point pass verifies every phi operand
    # numeric) become globally visible. This includes the phi itself: consumers such
    # as convert(T, phi) must see the proven type, not an erased Any while the local
    # silently uses a different representation. Optimistic box-solver joins remain
    # local-only hints.
    for (_jk, _jv) in (@isdefined(_conservative_joins) ? _conservative_joins : _numeric_joins)
        local _orig = get(ctx.ssa_types, _jk, Any)
        if _orig === Any || _orig isa Union
            ctx.ssa_types[_jk] = _jv
        end
    end
    refine_checked_cast_types!(ctx)   # parity(code_generator.dart:3170 CodeGenerator.visitAsExpression): dart `as T` — see the helper

    # Allocate locals for phi nodes (they need to persist across iterations)
    for (i, rec) in enumerate(nir)
        if rec.node isa NirPhi
            # Preserve missing type evidence as Any; never guess a numeric phi.
            # analyze_ssa_types! skips Any-typed SSAs, but phi nodes with type Any
            # must map to ExternRef, not I64. Fall back to inference's own type first.
            phi_julia_type = get(ctx.ssa_types, i, rec.julia_type)
            haskey(_numeric_joins, i) && (phi_julia_type = _numeric_joins[i])
            phi_wasm_type = get_concrete_wasm_type(phi_julia_type, ctx.mod, ctx.type_registry; for_local=true)

            # For phi nodes with all-numeric Union types (e.g., Union{Int64, UInt32}),
            # use the widest numeric type instead of tagged union. Tagged union (ConcreteRef)
            # can't store/load raw numeric values — the phi edges emit numeric constants
            # but the ConcreteRef local expects a struct reference, causing ref.null defaults.
            if phi_wasm_type isa ConcreteRef && phi_julia_type isa Union
                types_u = Base.uniontypes(phi_julia_type)
                non_nothing = filter(t -> t !== Nothing, types_u)
                all_numeric = all(non_nothing) do t
                    wt = julia_to_wasm_type(t)
                    wt === I32 || wt === I64 || wt === F32 || wt === F64
                end
                if all_numeric && !isempty(non_nothing)
                    # Route through THE single resolver (get_concrete_wasm_type →
                    # _resolve_multivariant_union) instead of the old lossy resolve_union_type,
                    # which collapsed mixed int/float (Union{Int64,Float64}) to F64 — losing the
                    # tag (Int 1 / Float 1.0 indistinguishable). The principled path boxes it (AnyRef),
                    # matching the value-type resolver + dart's top type. Same-category → widest (same).
                    phi_wasm_type = get_concrete_wasm_type(phi_julia_type, ctx.mod, ctx.type_registry; for_local=true)
                end
            end

            # Phi locals always use the type derived from the phi's Julia type.
            # Edge type incompatibility is handled downstream by
            # set_phi_locals_for_edge! and the inline phi handler,
            # which emit type-safe defaults for incompatible edges.

            # If this phi is used directly in a ReturnNode, and the function's
            # Wasm return type is numeric but the phi was allocated as ref, override
            # the phi local's type to match the function's return type.
            # This handles cases like Union{Int64, SomeStruct} phi where Julia type
            # inference produces a tagged union (ref), but the function actually returns i64.
            # Bottom/Nothing functions have no physical Wasm result. They may still
            # contain phis in their real throwing bodies, but there is no return
            # representation against which those locals can be overridden.
            func_ret_wasm = (ctx.return_type === Union{} || ctx.return_type === Nothing) ?
                nothing : get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
            is_func_ret_numeric = func_ret_wasm === I32 || func_ret_wasm === I64 ||
                                  func_ret_wasm === F32 || func_ret_wasm === F64
            is_phi_ref = phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef ||
                         phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef ||
                         phi_wasm_type === ExternRef || phi_wasm_type === EqRef

            if is_func_ret_numeric && is_phi_ref
                # Check if this phi is used in a ReturnNode
                phi_used_in_return = any(nir) do other
                    other.node isa NirReturn && other.node.value isa NirSSA &&
                        other.node.value.id == i
                end
                if phi_used_in_return
                    # Override phi type to match function return type
                    phi_wasm_type = func_ret_wasm
                end
            end

            # If phi type is a ref type but used in boolean context (i32_eqz,
            # not_int, eq_int, etc), override to I32. This handles dead code paths where
            # ref-typed phi values are tested with boolean operations.
            # Skip this override for Int128/UInt128 phi types.
            # These are primitive in Julia but map to struct{i64,i64} in Wasm.
            # They're used in comparison ops (sle_int, eq_int) but the phi local must
            # stay as ConcreteRef — the boolean ops receive extracted fields via struct_get.
            is_phi_any_ref = phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef ||
                             phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef ||
                             phi_wasm_type === ExternRef || phi_wasm_type === EqRef
            is_wasm_struct_numeric = phi_julia_type in (Int128, UInt128)
            if is_phi_any_ref && !is_wasm_struct_numeric
                for use_rec in nir
                    use_node = use_rec.node
                    # Check if used as GotoIfNot condition
                    if use_node isa NirGotoIfNot && use_node.cond isa NirSSA && use_node.cond.id == i
                        phi_wasm_type = I32
                        break
                    end
                    # Check if used as argument to boolean/comparison/arithmetic intrinsics
                    if use_rec.slot == 0 && use_node isa NirCall && !isempty(use_node.operands)
                        func = use_node.callee
                        if func isa Core.IntrinsicFunction
                            fname = nameof(func)
                            is_bool_op = fname in _BOOL_OP_INTRINSICS
                            is_cmp_op = fname in _CMP_OP_INTRINSICS
                            # Arithmetic intrinsics that require numeric operands
                            is_arith_op = fname in _NUMERIC_OP_INTRINSICS
                            if is_bool_op || is_cmp_op || is_arith_op
                                for arg in use_node.operands
                                    if arg isa NirSSA && arg.id == i
                                        if is_arith_op || is_cmp_op
                                            # Arithmetic/comparison ops need I64 (Julia's default int width)
                                            inferred = get_concrete_wasm_type(phi_julia_type, ctx.mod, ctx.type_registry; for_local=true)
                                            if inferred === I64
                                                phi_wasm_type = I64
                                            elseif inferred === I32
                                                phi_wasm_type = I32
                                            end
                                        else
                                            phi_wasm_type = I32  # Boolean ops
                                        end
                                        break
                                    end
                                end
                                (phi_wasm_type === I32 || phi_wasm_type === I64) && break
                            end
                        end
                    end
                end
            end

            local_idx = ctx.n_params + length(ctx.locals)
            # Trace externref phi allocations
            if get(ENV, "WASMTARGET_DEBUG_LOCALS", "") == "1"
                n_stmts = length(nir)
                @warn "ALLOC PHI local $local_idx type=$(phi_wasm_type) for SSA $i (stmts=$n_stmts, n_params=$(ctx.n_params))" maxlog=200
            end
            # normalize AnyRef → ExternRef for phi locals
            # Exception — keep AnyRef when $JlType hierarchy is active
            local phi_actual = phi_wasm_type
            if phi_wasm_type === AnyRef && ctx.type_registry.jl_type_idx === nothing
                phi_actual = ExternRef
            end
            push!(ctx.locals, phi_actual)
            ctx.phi_locals[i] = local_idx
        end
    end

    # Allocate locals for PhiCNode values (exception handler value capture).
    # PhiCNode is the dual of UpsilonNode: UpsilonNode stores, PhiCNode reads.
    # Each PhiCNode gets a local so UpsilonNode can local.set and PhiCNode can local.get.
    for (i, rec) in enumerate(nir)
        if rec.node isa NirPhiC
            phic_julia_type = get(ctx.ssa_types, i, rec.julia_type)
            phic_wasm_type = get_concrete_wasm_type(phic_julia_type, ctx.mod, ctx.type_registry; for_local=true)
            local_idx = ctx.n_params + length(ctx.locals)
            # normalize AnyRef → ExternRef unless JlType hierarchy active
            local phic_actual = phic_wasm_type
            if phic_wasm_type === AnyRef && ctx.type_registry.jl_type_idx === nothing
                phic_actual = ExternRef
            end
            push!(ctx.locals, phic_actual)
            ctx.phi_locals[i] = local_idx
        end
    end
end

"""
Allocate locals for SSA values that need them.
We need locals when:
1. An SSA value is used multiple times
2. An SSA value is not used immediately (intervening stack operations)
3. An SSA value is used in a multi-arg call where a sibling arg has a local
4. An SSA value is defined inside a loop but used outside (e.g., in return)
"""
function allocate_ssa_locals!(ctx::AbstractCompilationContext)
    nir = ctx.nir
    # parity(translator.dart:2100 Translator.translateTypeOfLocalVariable): Any-but-really-numeric JOIN (see the phi-allocation site for the design).
    _numeric_joins = try
        # Parent side: record %new(Core.Box) contents types per capturing closure type
        # (feeds the closure-side seeding below when THAT closure's body compiles).
        populate_box_field_types!(ctx.mod, ctx.type_registry, ctx.nir, ctx.ssa_types)
        _joins = propagate_numeric_value_types(ctx.nir, ctx.ssa_types;
            argtypes=ctx.arg_types, self_shift=(ctx.is_compiled_closure ? 0 : 1))
        # Closure side: seed the captured-Box getfields with the recorded contents type
        # (dart translateTypeOfLocalVariable for captures), then propagate through the body.
        # Closure-LOCAL typed capture: solve the self-captured Box contents type from the
        # body alone (optimistic + verified) — covers the parent-scalar-replaced case.
        _sbT = ctx.func_ref isa DataType ? ctx.func_ref : typeof(ctx.func_ref)
        if _sbT isa DataType && isstructtype(_sbT)
            _sst = ctx.nir   # Julia inference's own SSA types (the NIR boundary's widened answer)
            _conservative_joins = copy(_joins)   # propagate output only (proven cycles)
            merge!(_joins, f3_self_box_joins(ctx.nir, _sst, _sbT;
                argtypes=ctx.arg_types, self_shift=1))
        end
        if _sbT isa DataType && ctx.type_registry.box_contents_types !== nothing
            _selfT = _sbT
            _bw = get(ctx.type_registry.box_contents_types, _selfT, nothing)
            _bj = _bw === I64 ? Int64 : _bw === I32 ? Int32 :
                  _bw === F64 ? Float64 : _bw === F32 ? Float32 : nothing
            if _bj !== nothing
                _seeds = f3_closure_box_seeds(ctx.nir, _selfT, _bj)
                if !isempty(_seeds)
                    merge!(_joins, f3_box_value_types(ctx.nir, ctx.ssa_types; extra_box_seeds=_seeds))
                    merge!(_joins, _seeds)
                end
            end
        end
        _joins
    catch
        rethrow()
    end
    # parity(translator.dart:2100 Translator.translateTypeOfLocalVariable): the join IS the variable's real type (dart translateTypeOfLocalVariable)
    # — visible to EVERY consumer, not just local allocation. Without this, compile_call
    # still saw `Any`, classified the accumulator `+` as dynamic, and emitted the
    # type-safe-default ZERO (the mutable-capture silent 0).
    # parity(translator.dart:2100 Translator.translateTypeOfLocalVariable): ONLY the CONSERVATIVE joins (the phi-cycle pass — every operand
    # proven numeric) become globally-visible types. The OPTIMISTIC box-solver joins
    # stay local-typing hints only (they poisoned print_to_string's string-carrying
    # accumulator when made visible).
    for (_jk, _jv) in (@isdefined(_conservative_joins) ? _conservative_joins : _numeric_joins)
        local _orig = get(ctx.ssa_types, _jk, Any)
        # Refine ERASED slots only, and only for CALL/INVOKE results (the M10a case:
        # the dynamic-+ classified off the stale Any). PHI slots keep their erased
        # type — their truth lives in the join-typed LOCAL, and rewriting them
        # desynced String-carrying phis in print_to_string (a String local receiving
        # a join-typed i32 edge).
        local _jrec = _jk >= 1 && _jk <= length(nir) ? nir[_jk] : nothing
        if (_orig === Any || _orig isa Union) && _jrec !== nothing && _jrec.slot == 0 &&
           (_jrec.node isa NirCall || _jrec.node isa NirInvoke)
            ctx.ssa_types[_jk] = _jv
        end
    end
    refine_checked_cast_types!(ctx)   # parity(code_generator.dart:3170 CodeGenerator.visitAsExpression): dart `as T` — see the helper

    # Count uses of each SSA value
    ssa_uses = Dict{Int, Int}()
    for rec in nir
        count_ssa_uses!(rec, ssa_uses)
    end

    # Find loop bounds (header to backward goto)
    loop_bounds = Dict{Int, Int}()  # header => back_edge_idx
    for (i, rec) in enumerate(nir)
        if rec.node isa NirGoto && rec.node.target < i
            # This is a backward jump
            loop_bounds[rec.node.target] = i
        end
    end
    _is_jump(k) = nir[k].node isa NirGoto || nir[k].node isa NirGotoIfNot

    # First pass: allocate locals for SSAs used more than once or with intervening ops
    needs_local_set = Set{Int}()
    first_goto_to = _first_goto_to(nir)

    # Find SSAs defined inside a loop but used outside
    # These need locals because stack values don't persist across Wasm block boundaries
    for (header, back_edge) in loop_bounds
        for i in eachindex(nir)
            # Check if SSA i is defined inside this loop
            if i >= header && i <= back_edge
                # Check if it's used after the loop (in return or other statements)
                for (j, other) in enumerate(nir)
                    if j > back_edge && nir_refs_ssa(other.node, i)
                        # SSA i is defined inside loop but used outside - needs local
                        push!(needs_local_set, i)
                        break
                    end
                end
            end
        end
    end

    # Find non-phi SSA values that are referenced by phi nodes
    # These MUST have locals because phi values are set at the jump site,
    # not where the SSA was computed (the value is no longer on the stack)
    for rec in nir
        if rec.node isa NirPhi
            for val in rec.node.values
                if val isa NirSSA && 1 <= val.id <= length(nir) && !(nir[val.id].node isa NirPhi)
                    # This is a non-phi SSA referenced by a phi - needs local
                    push!(needs_local_set, val.id)
                end
            end
        end
    end

    # Find SSA values referenced by PiNodes that have control flow between definition and use
    # PiNodes narrow types after branch conditions, but the original value must be preserved
    for (i, rec) in enumerate(nir)
        if rec.node isa NirPi && rec.node.value isa NirSSA
            val_id = rec.node.value.id
            # Check if there's control flow between the definition and this PiNode
            if any(_is_jump, (val_id + 1):(i - 1))
                push!(needs_local_set, val_id)
            end
        end
    end

    # Find SSAs that produce values and are followed by control flow
    # In Wasm, stack values don't persist across block boundaries
    # So any value produced before a GotoNode/GotoIfNot/PhiNode must be stored
    for (i, rec) in enumerate(nir)
        if produces_stack_value(rec) && i < length(nir)
            # If the NEXT statement is control flow (not intermediate), this SSA needs a local
            # This handles cases where we create a value and immediately enter control flow
            if _is_jump(i + 1)
                push!(needs_local_set, i)
            end
        end
        # PiNodes used across control flow boundaries need locals.
        # Without a local, compile_value assumes the value is on the stack,
        # but in branching code the stack value may be in a different block.
        if rec.node isa NirPi && !haskey(ctx.phi_locals, i)
            # Check if there's any control flow between this PiNode and its uses
            for j in (i+1):length(nir)
                use_node = nir[j].node
                if nir_refs_ssa(use_node, i) && !(use_node isa NirPhi)
                    # Found a non-phi use. If there's control flow between PiNode and use, need a local.
                    if any(_is_jump, (i+1):(j-1))
                        push!(needs_local_set, i)
                        break
                    end
                end
            end
        end
    end

    # Find SSA values used across control flow boundaries.
    # In Wasm, stack values don't persist across block/branch boundaries.
    # Any SSA defined before a GotoNode/GotoIfNot and used after it needs a local.
    for (i, rec) in enumerate(nir)
        if produces_stack_value(rec)
            # Check all uses of this SSA
            for j in (i+1):length(nir)
                if nir_refs_ssa(nir[j].node, i)
                    # Check if there's any control flow between definition and use
                    if any(_is_jump, (i+1):(j-1))
                        push!(needs_local_set, i)
                        break
                    end
                end
            end
        end
    end

    for (ssa_id, use_count) in ssa_uses
        if haskey(ctx.phi_locals, ssa_id)
            # Phi nodes already have locals
            ctx.ssa_locals[ssa_id] = ctx.phi_locals[ssa_id]
        elseif use_count > 1 || needs_local(ctx, ssa_id, first_goto_to)
            push!(needs_local_set, ssa_id)
        end
    end

    # Second pass: ALL SSA args in calls/invokes/new/return/GotoIfNot need locals.
    # In Wasm, we can't rely on stack values being available because the stackified
    # flow generator may insert block boundaries between the SSA definition and its use.
    for rec in nir
        node = rec.node
        # All SSA values a statement lists directly need locals
        for arg in nir_direct_operands(rec)
            arg isa NirSSA && push!(needs_local_set, arg.id)
        end
        if node isa NirReturn && node.value isa NirSSA
            push!(needs_local_set, node.value.id)
        elseif node isa NirGotoIfNot && node.cond isa NirSSA
            push!(needs_local_set, node.cond.id)
        elseif node isa NirPi && node.value isa NirSSA
            push!(needs_local_set, node.value.id)
        end
        rec.slot == 0 || continue

        # Also handle :new expressions - struct fields need correct ordering
        if node isa NirNew
            field_values = node.operands
            ssa_args = [arg.id for arg in field_values if arg isa NirSSA]

            # If there are multiple field values and any is an SSA, all SSA args need locals
            # This ensures we can push values in the correct field order
            if length(field_values) > 1 && !isempty(ssa_args)
                for id in ssa_args
                    push!(needs_local_set, id)
                end
            end
        end

        node isa NirCall || continue
        args = node.operands

        # Handle setfield! - the value arg needs a local if it's an SSA
        # because struct.set expects [ref, value] order, but if value is a single-use
        # SSA from a previous statement, it's already on the stack before we push ref
        if node.callee === Core.setfield! && length(args) >= 3
            value_arg = args[3]  # operands = [obj, field, value]
            if value_arg isa NirSSA
                push!(needs_local_set, value_arg.id)
            end
        end

        # Handle :call expressions where a non-SSA arg appears BEFORE an SSA arg
        # This causes stack ordering issues: the SSA from the previous statement
        # is already on the stack, but we need to push the non-SSA first.
        # Example: slt_int(0, %1) - need to push 0, then %1, but %1 is already on stack
        # ONLY applies to numeric SSA values (struct refs have different handling)
        seen_non_ssa = false
        for arg in args
            if !(arg isa NirSSA)
                seen_non_ssa = true
            elseif seen_non_ssa
                # This SSA comes after a non-SSA arg - needs a local
                ssa_type = get(ctx.ssa_types, arg.id, Any)
                is_numeric = ssa_type in (Int32, UInt32, Int64, UInt64, Int, Float32, Float64, Bool)
                if is_numeric
                    push!(needs_local_set, arg.id)
                end
            end
        end

        # Handle Core.tuple calls - same as :new, need locals for SSA args
        # when there are multiple elements to ensure correct struct.new field ordering
        if node.callee === Core.tuple
            ssa_args = [arg.id for arg in args if arg isa NirSSA]
            # If there are multiple SSA args, all of them need locals to ensure
            # correct ordering (even if there are no non-SSA args)
            # Also need locals if there are non-SSA args mixed with SSA args
            has_non_ssa_args = any(!(arg isa NirSSA) for arg in args)
            if (has_non_ssa_args && !isempty(ssa_args)) || length(ssa_args) > 1
                for id in ssa_args
                    push!(needs_local_set, id)
                end
            end
        end

    end

    # Actually allocate the locals
    for ssa_id in sort(collect(needs_local_set))
        if !haskey(ctx.ssa_locals, ssa_id)  # Skip phi nodes already added
            ssa_type = get(ctx.ssa_types, ssa_id, Any)

            # Skip Task SSAs (from jl_get_current_task foreigncall)
            # Task values are phantom — rngState fields map to Wasm globals
            rec = nir[ssa_id]
            node = rec.node
            # the call this SSA is the result of (a statement, not a slot assignment)
            call = (rec.slot == 0 && node isa NirCall) ? node : nothing
            if rec.slot == 0 && node isa NirForeignCall && node.c_symbol === :jl_get_current_task
                continue
            end

            # An indexed MemoryRef, memoryrefnew(p, i, bc), has no local: the pair channel
            # (builtins.jl) re-emits it from its operands wherever it is read.
            if call !== nothing && _nir_callee_object(call.callee) === Core.memoryrefnew &&
               length(call.operands) >= 3
                continue
            end

            # _svec_ref results — Julia infers return type as SimpleVector,
            # but the actual WasmGC type is (ref null $JlType) (element of SVec array).
            # Override to AnyRef so the local matches what array.get actually produces.
            if call !== nothing && ssa_type === Core.SimpleVector &&
               isdefined(Core, :_svec_ref) && _nir_callee_object(call.callee) === Core._svec_ref
                ssa_type = Any
                ctx.ssa_types[ssa_id] = Any
            end

            # compilerbarrier(:type, value)::Any — use inner value's type
            # Runtime intrinsics use @noinline + inferencebarrier, which inserts
            # compilerbarrier(:type, value)::Any. The SSA type is Any → ExternRef,
            # but the actual value is the inner arg's type (e.g., Int32 → I32).
            # If we allocate ExternRef, the safety check replaces the i32 with ref.null.
            # Also update ctx.ssa_types so compile_statement safety check uses the real type.
            if call !== nothing && call.callee === Core.compilerbarrier && length(call.operands) >= 2
                inner_val = call.operands[2]  # operands = [kind, value]
                inner_type = nothing
                if inner_val isa NirSSA
                    inner_type = get(ctx.ssa_types, inner_val.id, nothing)
                elseif inner_val isa NirArgument
                    arg_idx = inner_val.n
                    if arg_idx <= length(ctx.arg_types)
                        inner_type = ctx.arg_types[arg_idx]
                    end
                elseif inner_val isa NirLiteral
                    # Literal value — infer type from the value itself
                    inner_type = typeof(inner_val.value)
                end
                if inner_type !== nothing && inner_type !== Any && inner_type !== Union{}
                    ssa_type = inner_type
                    ctx.ssa_types[ssa_id] = inner_type  # Update for safety check
                end
            end

            # typeof(x) always returns the canonical DataType representation.
            # The lookup table is created before any function body is emitted.
            if call !== nothing && _nir_callee_object(call.callee) === Core.typeof
                ctx.type_registry.type_lookup_global === nothing &&
                    error("typeof lowering requires the canonical type lookup table")
                haskey(ctx.type_registry.structs, DataType) ||
                    error("typeof lowering requires the canonical DataType representation")
                ssa_type = DataType
                ctx.ssa_types[ssa_id] = DataType
            end

            # :the_exception produces anyref from global.get $current_exn.
            # For Union exception types, override to Any so the local is anyref
            # (not the Union's tagged union type, which would cause illegal cast).
            # For concrete exception types (ErrorException etc.), keep the original
            # type so getfield can resolve struct fields — the :the_exception handler
            # in statements.jl will emit ref.cast from anyref to the concrete type.
            if rec.slot == 0 && node isa NirTheException
                if ssa_type isa Union || !isconcretetype(ssa_type) || !isstructtype(ssa_type)
                    ssa_type = Any
                    ctx.ssa_types[ssa_id] = Any
                end
            end

            # Skip Nothing type - nothing is compiled as ref.null, not i32
            # Trying to store it in an i32 local causes type errors
            if ssa_type === Nothing
                continue
            end

            # Skip bottom type (Union{}) - unreachable code
            if ssa_type === Union{}
                continue
            end

            # For PiNodes: the local type must match what compile_value(node.value)
            # will actually push on the stack. If the source value has a local,
            # that local's type is what will be on the stack (via local.get).
            effective_type = ssa_type
            # parity(translator.dart:2100 Translator.translateTypeOfLocalVariable): Any-but-really-numeric SSAs take their JOIN type (see above).
            haskey(_numeric_joins, ssa_id) && (effective_type = _numeric_joins[ssa_id])
            if node isa NirPi
                narrowed_wasm = get_concrete_wasm_type(ssa_type, ctx.mod, ctx.type_registry; for_local=true)
                # Check if the source value has a local with a different type
                src_wasm_type = nothing
                if node.value isa NirSSA
                    if haskey(ctx.ssa_locals, node.value.id)
                        src_local_idx = ctx.ssa_locals[node.value.id]
                        src_array_idx = src_local_idx - ctx.n_params + 1
                        if src_array_idx >= 1 && src_array_idx <= length(ctx.locals)
                            src_wasm_type = ctx.locals[src_array_idx]
                        end
                    elseif haskey(ctx.phi_locals, node.value.id)
                        src_local_idx = ctx.phi_locals[node.value.id]
                        src_array_idx = src_local_idx - ctx.n_params + 1
                        if src_array_idx >= 1 && src_array_idx <= length(ctx.locals)
                            src_wasm_type = ctx.locals[src_array_idx]
                        end
                    end
                end
                if src_wasm_type !== nothing && src_wasm_type != narrowed_wasm
                    # Source local has a different Wasm type than the narrowed type.
                    # Use the source's actual type for this local so local.get → local.set
                    # doesn't produce a type mismatch.
                    # Skip get_concrete_wasm_type for effective_type — we'll set wasm_type directly below.
                elseif !(narrowed_wasm isa ConcreteRef) && narrowed_wasm !== StructRef && narrowed_wasm !== ArrayRef && narrowed_wasm !== AnyRef
                    # Numeric PiNode — use the value's type for the local since
                    # the Wasm representation is the same (i32/i64/f32/f64)
                    # But NOT when the source is anyref (Union boxing).
                    # PiNode π(x::Union{Int32,Float64}, Int32) should allocate I32,
                    # not the Union's type. The unboxing in compile_statement extracts
                    # the concrete numeric value from the anyref box.
                    # For PiNode from anyref Union params, keep narrowed type
                    # (don't widen to source's Union type). For non-Union sources, use source type.
                    local _pi_src_is_anyref = false
                    if node.value isa NirArgument
                        arg_idx = node.value.n
                        if arg_idx <= length(ctx.slot_types)
                            local _slot_type = ctx.slot_types[arg_idx]
                            if _slot_type isa Union && needs_anyref_boxing(_slot_type)
                                _pi_src_is_anyref = true
                                # Keep effective_type = ssa_type (the narrowed target)
                            end
                        end
                    elseif node.value isa NirSSA
                        val_type = get(ctx.ssa_types, node.value.id, nothing)
                        if val_type !== nothing && val_type isa Union && needs_anyref_boxing(val_type)
                            _pi_src_is_anyref = true
                        end
                    end
                    if !_pi_src_is_anyref
                        # Non-Union source: use source type for compatible locals
                        if node.value isa NirSSA
                            val_type = get(ctx.ssa_types, node.value.id, nothing)
                            if val_type !== nothing
                                effective_type = val_type
                            end
                        elseif node.value isa NirArgument
                            arg_idx = node.value.n
                            if arg_idx <= length(ctx.slot_types)
                                effective_type = ctx.slot_types[arg_idx]
                            end
                        end
                    end
                end
            end

            wasm_type = get_concrete_wasm_type(effective_type, ctx.mod, ctx.type_registry; for_local=true)

            # For PiNodes where source local has a different NUMERIC type,
            # use the source's actual Wasm type to avoid local.get → local.set mismatches.
            # For ref types, DON'T widen — the compile_statement safety check handles
            # the store mismatch by emitting ref.null of the target type. Widening ref
            # types breaks downstream struct.get/array.get operations.
            if node isa NirPi && node.value isa NirSSA
                src_local_wasm = nothing
                if haskey(ctx.ssa_locals, node.value.id)
                    src_li = ctx.ssa_locals[node.value.id]
                    src_ai = src_li - ctx.n_params + 1
                    if src_ai >= 1 && src_ai <= length(ctx.locals)
                        src_local_wasm = ctx.locals[src_ai]
                    end
                elseif haskey(ctx.phi_locals, node.value.id)
                    src_li = ctx.phi_locals[node.value.id]
                    src_ai = src_li - ctx.n_params + 1
                    if src_ai >= 1 && src_ai <= length(ctx.locals)
                        src_local_wasm = ctx.locals[src_ai]
                    end
                end
                # Only widen for numeric type mismatches (I32/I64/F32/F64)
                # Ref type widening breaks struct.get downstream
                if src_local_wasm !== nothing && src_local_wasm != wasm_type
                    is_numeric_src = src_local_wasm === I32 || src_local_wasm === I64 ||
                                     src_local_wasm === F32 || src_local_wasm === F64
                    is_numeric_tgt = wasm_type === I32 || wasm_type === I64 ||
                                     wasm_type === F32 || wasm_type === F64
                    # Also allow widening when source is numeric but target is
                    # ConcreteRef from an all-numeric Union (e.g., Union{Int64, UInt32}).
                    # The phi was widened to I64, but the PiNode SSA got ConcreteRef from
                    # get_concrete_wasm_type. Use the source's numeric type.
                    is_numeric_union_tgt = wasm_type isa ConcreteRef && effective_type isa Union &&
                        let ut = Base.uniontypes(effective_type),
                            nn = filter(t -> t !== Nothing, ut)
                            !isempty(nn) && all(t -> let wt = julia_to_wasm_type(t); wt === I32 || wt === I64 || wt === F32 || wt === F64 end, nn)
                        end
                    # Don't widen I32 → I64 for PiNodes. The PiNode's
                    # compile_statement handler emits i32_wrap_i64 to convert the
                    # I64 phi value to I32, so the PiNode local should stay I32.
                    # Widening breaks downstream i32 operations (i32_sub, etc).
                    is_narrowing = src_local_wasm === I64 && wasm_type === I32
                    if is_numeric_src && (is_numeric_tgt || is_numeric_union_tgt) && !is_narrowing
                        wasm_type = src_local_wasm
                    end
                end
            end

            # Fix: if this SSA is a getfield/getproperty on a struct field typed as Any,
            # the Wasm struct.get returns externref. The local MUST be externref to match,
            # regardless of what Julia's type inference says the narrowed type is.
            # Similarly for memoryrefget on arrays with Any elements.
            if call !== nothing && length(call.operands) >= 2
                sfunc = call.callee
                if _is_getfield_callee(sfunc)
                    obj_arg = call.operands[1]
                    field_ref = call.operands[2]
                    obj_type = infer_value_type(obj_arg, ctx)
                    if obj_type isa DataType && isstructtype(obj_type) && !isprimitivetype(obj_type)
                        field_sym = field_ref isa NirLiteral ? field_ref.value : field_ref
                        if field_sym isa Symbol && hasfield(obj_type, field_sym)
                            jft = fieldtype(obj_type, field_sym)
                            if jft === Any
                                # ExternRef unless JlType hierarchy active
                                wasm_type = ctx.type_registry.jl_type_idx !== nothing ? AnyRef : ExternRef
                            end
                        end
                    end
                end
                # Also check memoryrefget on Any-element arrays
                if sfunc === Core.memoryrefget
                    ref_arg = call.operands[1]
                    ref_type = infer_value_type(ref_arg, ctx)
                    if ref_type isa DataType
                        elt = nothing
                        if ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1
                            elt = ref_type.parameters[1]
                        elseif ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2
                            elt = ref_type.parameters[2]
                        end
                        if elt === Any
                            # ExternRef unless JlType hierarchy active
                            wasm_type = ctx.type_registry.jl_type_idx !== nothing ? AnyRef : ExternRef
                        end
                    end
                end
            end

            # Fix When wasm_type is ExternRef but SSA is used in numeric context,
            # type the local based on the Julia type inference to match the expected operand type.
            # This handles dead code after UNREACHABLE and Any-typed struct fields used in comparisons.
            if wasm_type === ExternRef
                for use_rec in nir
                    use_node = use_rec.node
                    # Check if used as GotoIfNot condition
                    if use_node isa NirGotoIfNot && use_node.cond isa NirSSA && use_node.cond.id == ssa_id
                        wasm_type = I32
                        break
                    end
                    # Check if used as argument to comparison/boolean intrinsics
                    if use_rec.slot == 0 && use_node isa NirCall && !isempty(use_node.operands)
                        func = use_node.callee
                        if func isa Core.IntrinsicFunction
                            fname = nameof(func)
                            # Boolean ops that take boolean/i32 operands
                            is_bool_op = fname in _BOOL_OP_INTRINSICS
                            # Comparison ops that can take i32 or i64 operands
                            is_cmp_op = fname in _CMP_OP_INTRINSICS
                            # Arithmetic and other numeric intrinsics that require
                            # numeric operands — fixes externref/i64 mismatch in builtin_effects
                            is_arith_op = fname in _NUMERIC_OP_INTRINSICS
                            if is_bool_op || is_cmp_op || is_arith_op
                                for arg in use_node.operands
                                    if arg isa NirSSA && arg.id == ssa_id
                                        # Use Julia type to determine correct Wasm operand type
                                        # Compute what Wasm type the Julia type would normally map to
                                        inferred_wasm = get_concrete_wasm_type(effective_type, ctx.mod, ctx.type_registry; for_local=true)
                                        if inferred_wasm === I64
                                            wasm_type = I64
                                        elseif inferred_wasm === I32 || is_bool_op
                                            wasm_type = I32
                                        elseif inferred_wasm isa ConcreteRef || inferred_wasm === ExternRef
                                            # For arithmetic ops with Any/Union type, the value must be
                                            # numeric — default to I64 (Julia's default integer width)
                                            if is_arith_op || is_cmp_op
                                                wasm_type = I64
                                            end
                                            # Boolean ops keep ExternRef (Int128/UInt128 handled differently)
                                        else
                                            # Default to I32 for other cases (F32/F64 shouldn't reach here)
                                            wasm_type = I32
                                        end
                                        break
                                    end
                                end
                                (wasm_type === I32 || wasm_type === I64) && break
                            end
                        end
                    end
                end
            end

            local_idx = ctx.n_params + length(ctx.locals)
            # Trace externref allocations for diagnostics
            if get(ENV, "WASMTARGET_DEBUG_LOCALS", "") == "1"
                n_stmts = length(nir)
                @warn "ALLOC SSA local $local_idx type=$(wasm_type) effective=$(effective_type) ssa_type=$(ssa_type) for SSA $ssa_id (stmts=$n_stmts, n_params=$(ctx.n_params))" maxlog=200
            end
            # normalize AnyRef → ExternRef for SSA locals
            # Exception — keep AnyRef when $JlType hierarchy is active
            local ssa_actual = wasm_type
            if wasm_type === AnyRef && ctx.type_registry.jl_type_idx === nothing
                ssa_actual = ExternRef
            end
            push!(ctx.locals, ssa_actual)
            ctx.ssa_locals[ssa_id] = local_idx
        end
    end

end

"""
Allocate WASM locals for slot variables in unoptimized IR (may_optimize=false).

In unoptimized IR, local variables are represented as SlotNumber assignments:
  code[i] = Expr(:(=), SlotNumber(n), rhs_expr)
  code[j] = SlotNumber(n)  # reads the assigned value

The NIR records such an assignment as `nir[i].slot = n`, its `node` classifying the rhs.
Slots 1..n_params+1 are the function self + arguments (mapped to WASM params).
Slots > n_params+1 are local variables that need dedicated WASM locals.

This function scans for slot assignments, determines their types from the SSA types,
and allocates WASM locals. The slot_locals dict maps SlotNumber.id → WASM local index.
"""
function allocate_slot_locals!(ctx::AbstractCompilationContext)
    n_arg_slots = length(ctx.arg_types) + 1  # slot 1 = self, slot 2..n+1 = args

    for (i, rec) in enumerate(ctx.nir)
        slot_id = rec.slot
        if slot_id > n_arg_slots && !haskey(ctx.slot_locals, slot_id)
            # Determine type from the SSA type of this statement
            ssa_type = get(ctx.ssa_types, i, Any)
            wasm_type = get_concrete_wasm_type(ssa_type, ctx.mod, ctx.type_registry; for_local=true)
            # Normalize AnyRef → ExternRef unless JlType hierarchy active
            if wasm_type === AnyRef && ctx.type_registry.jl_type_idx === nothing
                wasm_type = ExternRef
            end
            local_idx = ctx.n_params + length(ctx.locals)
            push!(ctx.locals, wasm_type)
            ctx.slot_locals[slot_id] = local_idx
        end
    end
end

"""
    _first_goto_to(nir) -> Dict{Int,Int}

For each statement that some `goto` targets, the index of the first such `goto` in statement
order — the loop back-edge `needs_local` asks about for every SSA value, computed once per
function instead of rescanning the body per value.
parity(quarantine: WT decides stack residency per Julia SSA value, a question dart2wasm's expression-tree codegen never asks; this indexes the Julia IR's gotos once for it.)
"""
function _first_goto_to(nir::Vector{NirStmt})::Dict{Int,Int}
    first = Dict{Int,Int}()
    for (i, rec) in enumerate(nir)
        node = rec.node
        node isa NirGoto && !haskey(first, node.target) && (first[node.target] = i)
    end
    return first
end

"""
Check if an SSA value needs a local (e.g., not used immediately or used after other stack-producing operations).
"""
function needs_local(ctx::AbstractCompilationContext, ssa_id::Int,
                     first_goto_to::Dict{Int,Int})::Bool
    nir = ctx.nir

    # Find where this SSA is used
    use_idx = findfirst(i -> i != ssa_id && nir_refs_ssa(nir[i].node, ssa_id), eachindex(nir))

    if use_idx === nothing
        return false  # Never used
    end

    # Follow passthrough chains: if the use is a single-arg memoryrefnew (passthrough),
    # the value stays on the stack and is actually consumed by the passthrough's consumer.
    # We need to check intervening statements between definition and ACTUAL consumer.
    actual_use_idx = use_idx
    visited = Set{Int}()
    while actual_use_idx ∉ visited
        push!(visited, actual_use_idx)
        use_rec = nir[actual_use_idx]
        use_node = use_rec.node
        # Check if this is a single-arg memoryrefnew passthrough
        if use_rec.slot == 0 && use_node isa NirCall &&
           (use_node.callee === Core.memoryrefnew || use_node.callee === Core.memoryref) &&
           length(use_node.operands) == 1  # single-arg passthrough
            # Find where this passthrough result is used
            next_use = findfirst(j -> j != actual_use_idx && nir_refs_ssa(nir[j].node, actual_use_idx),
                                 eachindex(nir))
            if next_use !== nothing
                actual_use_idx = next_use
                continue
            end
        end
        break
    end

    # If there are any statements between definition and use that produce values,
    # we need a local because those values will mess up the stack
    for i in (ssa_id + 1):(actual_use_idx - 1)
        if produces_stack_value(nir[i])
            return true
        end
    end

    # Also need local if there's control flow between definition and use
    for i in (ssa_id + 1):(actual_use_idx - 1)
        if nir[i].node isa NirGotoIfNot || nir[i].node isa NirGoto
            return true
        end
    end

    # If SSA is defined inside a loop and there are conditionals in the loop,
    # we need a local to ensure stack balance across control flow
    for header in 1:length(ctx.loop_headers)
        ctx.loop_headers[header] || continue
        # Find corresponding back-edge: the first `goto` to this header, found once per
        # function (`_first_goto_to`)
        back_edge = get(first_goto_to, header, nothing)
        if back_edge !== nothing && ssa_id >= header && ssa_id <= back_edge
            # SSA is defined inside this loop
            # Check if there are any conditionals in the loop
            for i in header:back_edge
                if nir[i].node isa NirGotoIfNot
                    # Loop has a conditional (not the exit condition if it's at the start)
                    if i != header && i != header + 1
                        return true
                    end
                end
            end
        end
    end

    return false
end

"""
Check if a statement produces a value on the stack: a call, invoke, `%new`, boundscheck,
exception read, phi or pi, or a statement that is itself a value. An assignment into a
slot stores its value instead.
"""
function produces_stack_value(rec::NirStmt)::Bool
    rec.slot > 0 && return false
    node = rec.node
    return node isa NirCall || node isa NirInvoke || node isa NirNew ||
           node isa NirBoundscheck || node isa NirTheException ||
           node isa NirPhi || node isa NirPi ||
           # Literals and SSA refs also produce values (but shouldn't appear as statements)
           node isa NirSSA || (node isa NirLiteral && node.value isa Number)
end

"""
Check if a statement is a passthrough that doesn't emit bytecode but relies on
a value already being on the stack from an earlier SSA.
Examples:
- memoryrefnew(memory) - just passes through the array reference
- Core.memoryref(memory) via :invoke - also a passthrough
Note: Vector{T} is NO LONGER a passthrough - it's now a struct with (ref, size) fields.
"""
function is_passthrough_statement(node::NirNode, ctx::AbstractCompilationContext)::Bool
    # Check for memoryrefnew with single arg (passthrough pattern) via :call
    if node isa NirCall && node.callee === Core.memoryrefnew && length(node.operands) == 1
        # Single arg memoryrefnew is a passthrough
        return true
    end

    # Check for Core.memoryref via :invoke - this is also a passthrough
    # Julia uses :invoke for Core.memoryref(memory::Memory{T}) -> MemoryRef{T}
    # In WasmGC, this is a no-op since Memory and MemoryRef are both the array
    if node isa NirInvoke && node.callee === Core.memoryref && length(node.operands) == 1
        arg = node.operands[1]
        # It's a passthrough if the single arg is an SSA that doesn't have a local
        # (meaning its value is still on the stack from the previous statement)
        if arg isa NirSSA && !haskey(ctx.ssa_locals, arg.id)
            return true
        end
    end

    # Note: Vector %new is NO LONGER a passthrough
    # Vector{T} is now a struct with (ref, size) fields for setfield! support

    return false
end

"""
Count the SSA uses one statement makes: every SSA operand an expression reads (its dynamic
callee included), a return's value, a branch condition, a phi's incoming values and a pi's
source. A statement that is itself an SSA value (or a slot assigned from one) is a use.
"""
function count_ssa_uses!(rec::NirStmt, uses::Dict{Int, Int})::Nothing
    _count(x) = (x isa NirSSA && (uses[x.id] = get(uses, x.id, 0) + 1); nothing)
    node = rec.node
    if node isa NirPhi
        foreach(v -> v === nothing || _count(v), node.values)
    elseif node isa NirPi
        # PiNode references a source value — count it so phi nodes
        # that are only referenced by PiNodes get their ssa_locals mapping
        _count(node.value)
    elseif node isa NirReturn
        node.value === nothing || _count(node.value)
    elseif node isa NirGotoIfNot
        _count(node.cond)
    elseif node isa NirSSA
        _count(node)
    else
        foreach(_count, nir_expr_operands(node))
    end
    return nothing
end

"""
The inferred source type of IR slot `slot` (slot 1 = `#self#`, then the parameters, then the
locals), as the NIR boundary widened it — `nothing` when the IR carries no slot table.
"""
function source_slot_type(ctx::AbstractCompilationContext, slot::Integer)::Union{Type, Nothing}
    1 <= slot <= length(ctx.slot_types) || return nothing
    return ctx.slot_types[slot]
end

"""Return the source tuple type when one IR argument is a flattened vararg pack.

`CodeInfo` exposes a vararg method's final source argument as `Tuple{...}`, while
the Wasm function signature contains each concrete vararg as a separate physical
parameter. An ordinary tuple argument has one matching physical tuple parameter
and is deliberately not classified as a pack.
"""
function packed_vararg_source_type(ctx::AbstractCompilationContext,
                                   source_slot::Integer,
                                   physical_start::Integer)::Union{Type, Nothing}
    T = source_slot_type(ctx, source_slot)
    T isa DataType && T <: Tuple || return nothing
    physical_start >= 1 || return nothing
    tail = physical_start <= length(ctx.arg_types) ?
        ctx.arg_types[physical_start:end] : ()
    length(tail) == 1 && tail[1] === T && return nothing
    params = T.parameters
    length(params) == length(tail) || return nothing
    for i in eachindex(params)
        p = params[i]
        p isa Type && tail[i] isa Type && p == tail[i] || return nothing
    end
    return T
end

function get_ssa_type(ctx::AbstractCompilationContext, val::NirNode)::Type
    if val isa NirSSA
        return get(ctx.ssa_types, val.id, Any)
    elseif val isa NirArgument
        # Core.Argument indexes Julia IR slots, whose inferred source contract
        # is CodeInfo.slottypes. `ctx.arg_types` is the flattened physical Wasm
        # signature and intentionally differs for packed Vararg slots, closures,
        # and other ABI transformations; it is only a legacy fallback when the
        # source slot table is unavailable.
        source_type = source_slot_type(ctx, val.n)
        source_type !== nothing && return source_type
        if ctx.is_compiled_closure
            idx = val.n
        else
            idx = val.n - 1
        end
        if idx >= 1 && idx <= length(ctx.arg_types)
            return ctx.arg_types[idx]
        end
        return Any
    elseif val isa NirLiteral
        # Literal Symbols and other quoted constants carry the type of their
        # payload; a Type literal is a type constant.
        return val.value isa Type ? Type{val.value} : typeof(val.value)
    elseif val isa NirGlobalRef && val.bound
        # a global operand is its bound value
        return val.value isa Type ? Type{val.value} : typeof(val.value)
    else
        return Any
    end
end

"""
Analyze the IR to determine types of SSA values.
Uses Julia inference's own SSA types (the NIR boundary's widened answer).
"""
function analyze_ssa_types!(ctx::AbstractCompilationContext)
    # Use Julia's type inference results when available. Store all concrete types
    # including Nothing (needed for function dispatch); only skip Any as it provides no
    # useful information. The boundary already widened inference lattice elements
    # (unoptimized IR's Core.Const/PartialStruct) to plain Julia types.
    for (i, rec) in enumerate(ctx.nir)
        rec.julia_type !== Any && (ctx.ssa_types[i] = rec.julia_type)
    end

    # Override: if an SSA is a getfield/getproperty on a struct field typed as Any,
    # or a memoryrefget on an array with Any elements, force the SSA type to Any.
    # This ensures the local is allocated as externref (matching what struct.get/array.get
    # actually produces), preventing type mismatches with local.set.
    for (i, rec) in enumerate(ctx.nir)
        rec.slot == 0 || continue
        node = rec.node
        if node isa NirForeignCall && node.c_symbol === :jl_type_unionall
            # Julia 1.13 can erase the SSA annotation for its UnionAll
            # predicate even though the C ABI and Julia operation both return
            # Bool. Keep allocation and the nominal ref.test emitter aligned.
            ctx.ssa_types[i] = Bool
        end
        if node isa NirCall && length(node.operands) >= 2
            func = node.callee
            # Check getfield/getproperty on Any-typed struct field
            # (Base's getproperty and the Compiler's own both lower to getfield)
            if _is_getfield_callee(func)
                obj_arg = node.operands[1]
                field_ref = node.operands[2]
                obj_type = infer_value_type(obj_arg, ctx)
                # Check the Julia field type directly (no registry lookup needed)
                # Also allow non-concrete Tuple types (e.g., Tuple{Any, Int64})
                # isconcretetype(Tuple{Any, Int64}) = false because Any is abstract, but
                # fieldtype/fieldcount still work correctly on Tuple DataTypes.
                is_concrete_enough = isconcretetype(obj_type) || (obj_type <: Tuple && obj_type isa DataType)
                if obj_type isa DataType && isstructtype(obj_type) && !isprimitivetype(obj_type) && is_concrete_enough
                    field_sym = field_ref isa NirLiteral ? field_ref.value : field_ref
                    julia_field_type = nothing
                    if field_sym isa Symbol && hasfield(obj_type, field_sym)
                        julia_field_type = fieldtype(obj_type, field_sym)
                    elseif field_sym isa Integer
                        fc = try fieldcount(obj_type) catch; -1 end
                        if fc >= 0 && 1 <= field_sym <= fc
                            julia_field_type = fieldtype(obj_type, Int(field_sym))
                        end
                    end
                    if julia_field_type === Any
                        ctx.ssa_types[i] = Any  # Force ExternRef local to match struct.get output
                    end
                end
            end
            # Check memoryrefget on Any-element array
            if func === Core.memoryrefget
                ref_arg = node.operands[1]
                ref_type = infer_value_type(ref_arg, ctx)
                elem_type = nothing  # unknown
                if ref_type isa DataType
                    if ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1
                        elem_type = ref_type.parameters[1]
                    elseif ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2
                        elem_type = ref_type.parameters[2]
                    end
                end
                if elem_type === Any
                    ctx.ssa_types[i] = Any  # Force ExternRef local to match array.get output
                end
            end
        end
    end

    # A statement Julia left `::Any` is re-asked of Julia only where its `Any` is a cutoff,
    # not an answer. A dynamic call to a known function: `closed_world_call_result`. An
    # `:invoke` whose value the optimizer left unused (the caller's IR then reads `::Any`):
    # its result is the invoked MethodInstance's own inferred return type, which the closed
    # world registered for exactly that signature; another specialization never answers.
    # parity(pkg/kernel/lib/src/ast/expressions.dart:2856 getStaticTypeInternal): a static
    # invocation's type is its target's return type.
    ctx.func_registry === nothing && return
    for (i, rec) in enumerate(ctx.nir)
        haskey(ctx.ssa_types, i) && continue
        rec.slot == 0 || continue
        node = rec.node
        if node isa NirCall
            local _cw = closed_world_call_result(ctx, node)
            _cw === Any || (ctx.ssa_types[i] = _cw)
            continue
        end
        (node isa NirInvoke && node.mi isa Core.MethodInstance) || continue
        func = node.callee
        (func isa NirNode || func isa GlobalRef || func === nothing) && continue
        infos = get_func_ref_infos(ctx.func_registry, func)
        infos === nothing && continue
        spec = node.mi.specTypes
        for info in infos
            if Tuple{typeof(func), info.arg_types...} == spec || Tuple{info.arg_types...} == spec
                ctx.ssa_types[i] = info.return_type
                break
            end
        end
    end
end

"""
    closed_world_call_result(ctx, call) -> Type

The result type of a call to a known function that Julia's inference left `::Any`. Julia
stops enumerating a call's methods at `max_methods`; this is Julia's own answer with that
cutoff lifted: every method applicable to the operands' Julia types, each inferred through
the one inference path and joined with Julia's `tmerge` (`Base.infer_return_type`). The
answer is used only when it is concrete; otherwise the call stays `Any`. An ambiguous or
unenumerable call stays `Any`. A concrete answer is used only when the call's dispatch can
reach every applicable method — each has a specialization in the closed world. Otherwise
the call stays `Any`: a method no allocated class reaches (`ncodeunits(::LazyString)` in a
program that makes no LazyString) is not evidence against the answer, but it is not in the
closed world to prove it either.
parity(pkg/vm/lib/transformations/type_flow/analysis.dart:535 process): a dynamic
invocation's type is the union of the results of all its possible targets.
"""
function closed_world_call_result(ctx::AbstractCompilationContext, call::NirCall)::Type
    ctx.func_registry === nothing && return Any
    f = _nir_callee_object(call.callee)
    (f isa Function || f isa Type) || return Any
    f isa Core.Builtin && return Any
    argtypes = Tuple(Any[get_ssa_type(ctx, a) for a in call.operands])
    interp = get_wasm_interpreter()
    table = CC.method_table(interp)
    lookup = CC.findall(Tuple{Core.Typeof(f), argtypes...}, table; limit=-1)
    (lookup === nothing || lookup.ambig || isempty(lookup.matches)) && return Any
    rt = infer_return_type(f, argtypes; interp=interp)
    isconcretetype(rt) || return Any
    reached = Set{Method}()
    for info in something(get_func_ref_infos(ctx.func_registry, f), FunctionInfo[])
        local sig = (!isempty(info.arg_types) && info.arg_types[1] === Core.Typeof(f) &&
                     length(info.arg_types) == length(argtypes) + 1) ?
                    Tuple{info.arg_types...} : Tuple{Core.Typeof(f), info.arg_types...}
        local own = CC.findall(sig, table; limit=1)
        (own === nothing || isempty(own.matches)) || push!(reached, own.matches[1].method)
    end
    all(match -> match.method in reached, lookup.matches) || return Any
    return rt
end

function infer_value_type(val::NirNode, ctx::AbstractCompilationContext)
    if val isa NirArgument
        # Source IR semantics are authoritative. The physical signature can be
        # flattened (notably a vararg tuple), so indexing ctx.arg_types first
        # can turn one Tuple source argument into its first physical element.
        source_type = source_slot_type(ctx, val.n)
        source_type !== nothing && return source_type
        # For closures being compiled, _1 is the closure object (arg_types[1])
        # For regular functions, arguments start at _2 (arg_types[1])
        # Use is_compiled_closure flag to distinguish (not the type of first arg)
        if ctx.is_compiled_closure
            # Closure: direct mapping (_1 = closure, _2 = first arg)
            idx = val.n
        else
            # Regular function: skip _1 (function type in IR)
            idx = val.n - 1
        end
        if idx >= 1 && idx <= length(ctx.arg_types)
            return ctx.arg_types[idx]
        elseif idx < 1 && ctx.func_ref !== nothing
            # Core.Argument(1) in a non-closure is the function reference itself.
            # This occurs in kwarg wrapper methods that pass `self` to the inner #method#N.
            # Return typeof(func_ref) so cross-function lookup can match the registered signature.
            return typeof(ctx.func_ref)
        end
    elseif val isa NirSlot
        # SlotNumber is the unoptimized IR equivalent of Core.Argument.
        # Slot 1 = function self, slot 2+ = arguments (same indexing as Argument).
        # For local variable slots (not params), use slottypes from CodeInfo.
        source_type = source_slot_type(ctx, val.id)
        source_type !== nothing && return source_type
        if ctx.is_compiled_closure
            idx = val.id
        else
            idx = val.id - 1
        end
        if idx >= 1 && idx <= length(ctx.arg_types)
            return ctx.arg_types[idx]
        end
    elseif val isa NirSSA
        return get(ctx.ssa_types, val.id, Any)
    elseif val isa NirGlobalRef
        # GlobalRef to a constant - infer type from the actual value
        if val.bound
            actual_val = val.value
            if actual_val isa Int32
                return Int32
            elseif actual_val isa Int64 || actual_val isa Int
                return Int64
            elseif actual_val isa Float32
                return Float32
            elseif actual_val isa Float64
                return Float64
            elseif actual_val isa Bool
                return Bool
            elseif actual_val isa Char
                return Char
            elseif actual_val isa Type
                # Return Type{actual_val} (e.g., Type{Int64}) instead of bare Type.
                # This allows get_concrete_wasm_type to return ConcreteRef for the DataType struct,
                # which triggers extern_convert_any bridging when passed to externref-typed params.
                return Type{actual_val}
            else
                return typeof(actual_val)
            end
        end
        # An unresolved global has no numeric type evidence; fall through to Any.
    elseif val isa NirLiteral
        lit = val.value
        if lit isa Symbol || lit isa Core.SSAValue || lit isa Core.Argument || lit isa Core.SlotNumber
            # a quoted literal carries the type of its payload
            return typeof(lit)
        elseif lit isa Int64 || lit isa Int
            return Int64
        elseif lit isa Int32
            return Int32
        elseif lit isa Float64
            return Float64
        elseif lit isa Float32
            return Float32
        elseif lit isa Bool
            return Bool
        elseif lit isa Char
            return Char
        elseif lit isa WasmGlobal
            return typeof(lit)
        elseif lit isa Type
            # Type{T} references - return Type{T}
            return Type{lit}
        elseif lit isa Function
            # Function values passed as arguments (e.g., kwarg wrappers pass `self` to inner method)
            # Return typeof(f) so cross-function lookup can match the registered signature
            return typeof(lit)
        elseif isprimitivetype(typeof(lit))
            # Custom primitive type (e.g., JuliaSyntax.Kind) - return actual type
            return typeof(lit)
        elseif isstructtype(typeof(lit)) && !isa(lit, Type) && !isa(lit, Function) && !isa(lit, Module)
            # Struct constant - return actual type
            return typeof(lit)
        end
    end
    return Any
end

"""
    _ref_cast_source_type(val, ctx)

Resolve the DECLARED wasm slot type of `val`'s source (SSA/phi local or parameter) —
feeds emit_ref_cast_if_structref!: when the source slot is abstract (structref/anyref)
or a mismatched concrete ref, a `ref.cast null \$target` narrows it for struct_get.
"""
function _ref_cast_source_type(val::NirNode, ctx::AbstractCompilationContext)
    if val isa NirSSA
        local_idx = get(ctx.ssa_locals, val.id, nothing)
        if local_idx === nothing
            local_idx = get(ctx.phi_locals, val.id, nothing)
        end
        if local_idx !== nothing
            arr_idx = local_idx - ctx.n_params + 1
            if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                return ctx.locals[arr_idx]
            end
        end
    elseif val isa NirArgument
        # the operand is a function PARAMETER. Its declared wasm slot
        # type can be abstract (structref/anyref) when the method was specialized
        # on an abstract value arg (e.g. `show(::IO, x)` where the body narrows x
        # to a concrete struct via inference) — the body then emits `struct.get
        # $Concrete` against a `structref` param and validation fails. Resolve the
        # param's DECLARED wasm type the same way the signature builder does
        # (compile.jl) so the cast matches the slot, not the (ideal) concrete type.
        arg_idx = ctx.is_compiled_closure ? val.n : val.n - 1
        if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
            T = ctx.arg_types[arg_idx]
            return (T isa Union && needs_anyref_boxing(T)) ? AnyRef :
                get_concrete_wasm_type(T, ctx.mod, ctx.type_registry)
        end
    end
    return nothing
end

"""builder-native form: resolve the source's declared wasm type and narrow on `b`."""
function emit_ref_cast_if_structref!(b::InstrBuilder, val, target_type_idx::Integer, ctx::AbstractCompilationContext)
    _emit_ref_cast_arm!(b, _ref_cast_source_type(val, ctx), target_type_idx)
    return b
end

"""builder-native core: with the source ref on `b`'s stack, narrow per the arm table."""
function _emit_ref_cast_arm!(b, local_wasm_type, target_type_idx::Integer)
    if local_wasm_type === StructRef || local_wasm_type === AnyRef
        # Value on stack is structref/anyref, but struct_get/array_get needs (ref null $target_type_idx)
        ref_cast!(b, Int64(target_type_idx), true)
    elseif local_wasm_type === ExternRef
        # Value on stack is externref (from Any-typed local or Dict/Vector retrieval).
        # Must convert externref → anyref → (ref null $target_type_idx) for struct_get.
        any_convert_extern!(b)
        ref_cast!(b, Int64(target_type_idx), true)
    elseif local_wasm_type isa ConcreteRef && local_wasm_type.type_idx != UInt32(target_type_idx)
        # Local is a specific ConcreteRef but points to a DIFFERENT struct
        # type than the one struct_get/array_get wants. This happens when
        # dispatch narrows a union-of-structs to one branch via PiNode +
        # local assignment: the local's declared type stays at the union's
        # representative (e.g. type 46), while the next getfield expects
        # the target branch's struct type (e.g. type 70). Without this
        # cast the browser rejects with:
        #     struct.get[0] expected type (ref null 70),
        #       found local.get of type (ref null 46)
        # `ref.cast null $target_type_idx` is a runtime narrowing — if
        # the value is actually of type `$target_type_idx` or a subtype
        # it passes cleanly; if not, the cast traps (same semantics as
        # Julia's abstract-dispatch failure).
        ref_cast!(b, Int64(target_type_idx), true)
    end
    return b
end

"""
    _narrow_generic_local!(b, local_idx, ssa_id, ctx) -> Bool

builder-native — THE implementation): when a local has generic type
(anyref/structref/externref/eqref) but the SSA's Julia type maps to a concrete Wasm
type, narrow the value on `b`'s stack (`ref.cast null` for refs — a no-op at runtime
when correct, a trap on a real codegen bug — and THE funnel-unbox for join-refined
numerics). Returns false when no narrowing applies.
"""
function _narrow_generic_local!(b::InstrBuilder, local_idx::Integer, ssa_id::Integer, ctx::AbstractCompilationContext)::Bool
    arr_idx = local_idx - ctx.n_params + 1
    if arr_idx < 1 || arr_idx > length(ctx.locals)
        return false
    end
    local_wasm_type = ctx.locals[arr_idx]
    if !(local_wasm_type === AnyRef || local_wasm_type === StructRef || local_wasm_type === ExternRef || local_wasm_type === EqRef)
        return false  # Local is already concrete — no narrowing needed
    end
    # Look up the SSA's Julia type to find a concrete Wasm type
    ssa_julia_type = get(ctx.ssa_types, ssa_id, Any)
    if ssa_julia_type === Any || ssa_julia_type === Union{}
        return false  # Can't narrow — don't know the concrete type
    end
    # Don't narrow Union{Nothing, T} types — the value may be Nothing,
    # and downstream code (e.g., === nothing comparison) needs the unnarrowed type.
    # Narrowing happens via PiNode after the null check succeeds.
    if ssa_julia_type isa Union
        return false
    end
    concrete_wasm = get_concrete_wasm_type(ssa_julia_type, ctx.mod, ctx.type_registry)
    if concrete_wasm isa ConcreteRef
        if local_wasm_type === ExternRef
            # ExternRef needs any_convert_extern before ref.cast
            any_convert_extern!(b)
        end
        ref_cast!(b, Int64(concrete_wasm.type_idx), true)
        return true
    elseif concrete_wasm === I32 || concrete_wasm === I64 ||
           concrete_wasm === F32 || concrete_wasm === F64
        # parity(translator.dart:1597 Translator.convertType): a join-typed NUMERIC riding a ref local UNBOXES through the ONE
        # funnel (dart convertType) — symmetric to the store-side box. Without this,
        # consumers read a raw box ref where the numeric is expected.
        coerce_stack_top!(b, concrete_wasm, ctx; from_julia=ssa_julia_type)
        return true
    end
    return false
end

"""
Extract the global index from a WasmGlobal type.
The index is stored as a type parameter, so we extract it from the type.
"""
function get_wasm_global_idx(val, ctx::AbstractCompilationContext)::Union{Int, Nothing}
    val_type = infer_value_type(val, ctx)
    if val_type <: WasmGlobal
        # Extract IDX from WasmGlobal{T, IDX}
        return global_index(val_type)
    end
    return nothing
end

# ============================================================================
