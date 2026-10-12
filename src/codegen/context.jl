# ============================================================================
# Compilation Context
# ============================================================================

"""
Abstract supertype for compilation contexts.
CompilationContext is the sole function-compilation context.
parity(pkg/dart2wasm/lib/code_generator.dart:28 CodeGenerator)
"""
abstract type AbstractCompilationContext end

"""
Tracks state during compilation of a single function.
parity(pkg/dart2wasm/lib/code_generator.dart:28 CodeGenerator)
"""
mutable struct CompilationContext <: AbstractCompilationContext
    arg_types::Tuple
    return_type::Type
    n_params::Int
    locals::Vector{WasmValType}  # Additional locals beyond params (supports refs)
    ssa_types::IntKeyMap{Type}   # SSA value -> Julia type
    ssa_locals::IntKeyMap{Int}   # SSA value -> local index (for multi-use SSAs)
    phi_locals::IntKeyMap{Int}   # PhiNode SSA -> local index
    mod::WasmModule              # The module being built
    translator::Translator       # the compilation's shared state (dart: CodeGenerator.translator)
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
    # per try region (by its enter), the top of the exception stack when it was entered,
    # restored at its pop_exception (Julia's exception stack; exc_saved_local!)
    exc_saved_locals::Dict{Int, Int}
    # NIR boundary (parity: code_generator.dart:77 typeContext) — frontend/nir.jl's
    # build_nir output, one record per IR statement. Built FIRST, from the typed IR alone,
    # so the analysis passes below are themselves NIR consumers rather than its
    # prerequisites; the context reads Julia's IR through it and nothing else.
    nir::Vector{NirStmt}
    # For each SSA id, the statements that use it, ascending (nir_ssa_users) — built with the
    # context; `nir` is never rewritten after (the stackifier threads its own copy).
    ssa_users::Dict{Int,Vector{Int}}
    # the body's CFG, Julia's own (nir_cfg), built with the context
    cfg::NirCFG
    # each statement's source-map provenance, computed once (map_to_statement!)
    stmt_sources::Dict{Int,Union{Nothing,SourceInfo}}
    # Julia inference's type for every IR slot, widened once at the boundary
    # (frontend/nir.jl's nir_slot_types) — what an Argument/SlotNumber operand is typed by.
    slot_types::Vector{Type}
    # The function's source-location table: a located diagnostic decodes a statement's
    # inline chain and the method's definition site from it (diagnostics.jl).
    debuginfo::Union{Core.DebugInfo, Nothing}
    # the function's wasm signature (function_wasm_signature), which its body builder and every
    # fragment carry: its parameters type locals 0 .. n_params-1, its results type every return
    wasm_params::Vector{WasmValType}
    wasm_results::Vector{WasmValType}
    # the planned body this context compiles (its joins are the plan's, plan_joins), or nothing
    # for a body the plan does not hold (the class-id reader's), which has no joins
    mi::Union{Nothing, Core.MethodInstance}
end

# parity(pkg/dart2wasm/lib/code_generator.dart:28 CodeGenerator)
function CompilationContext(body::NirBody, arg_types::Tuple, return_type, mod::WasmModule, type_registry::TypeRegistry;
                           translator::Translator,
                           func_registry::Union{FunctionRegistry, Nothing}=nothing,
                           func_idx::UInt32=UInt32(0), func_ref=nothing,
                           global_args::Set{Int}=Set{Int}(),
                           is_compiled_closure::Bool=false,
                           captured_signal_fields::Dict{Symbol, Tuple{Bool, UInt32}}=Dict{Symbol, Tuple{Bool, UInt32}}(),
                           captured_constant_fields::Dict{Symbol, Any}=Dict{Symbol, Any}(),
                           dom_bindings::Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}=Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}(),
                           dispatch_registry::Union{Nothing, DispatchTableRegistry}=nothing,
                           skip_stmts::Set{Int}=Set{Int}(),
                           invoke_imports::Dict{Int, UInt32}=Dict{Int, UInt32}(),
                           mi::Union{Nothing, Core.MethodInstance})::CompilationContext
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
        mod,
        translator,
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
        Dict{Int, Int}(),              # exc_saved_locals
        body.stmts,             # NIR boundary — built first, from the typed IR alone
        nir_ssa_users(body.stmts),
        nir_cfg(body.stmts),
        Dict{Int,Union{Nothing,SourceInfo}}(),
        body.slot_types,
        body.debuginfo,
        function_wasm_signature(arg_types, return_type, global_args, mod, type_registry)...,
        mi
    )
    # Each SSA's type is the NIR boundary's (Julia inference's own answer, widened), with the
    # plan's joins applied in analyze_control_flow!; nothing else retypes it before emission
    # (parity(code_generator.dart:129 CodeGenerator.dartTypeOf): one static type per expression).
    # An `Any` SSA has no entry: value_type reads the node's own type for it. An `:invoke` whose
    # value the optimizer left unused reads `::Any` in the caller's IR, which is no answer for
    # it: its type is the return type of the function it calls, the one compile_invoke! calls
    # (get_function_by_mi): a planned body's is its rettype in the plan, a declared import's its
    # declared one; a MethodInstance with no function rejects at its statement
    # (parity(pkg/kernel/lib/src/ast/expressions.dart:2856 getStaticTypeInternal): a static
    # invocation's type is its target's return type).
    for (i, rec) in enumerate(ctx.nir)
        if rec.julia_type !== Any
            ctx.ssa_types[i] = rec.julia_type
        elseif ctx.func_registry !== nothing && rec.slot == 0 && rec.node isa NirInvoke &&
               rec.node.mi isa Core.MethodInstance
            local target = get_function_by_mi(ctx.func_registry, rec.node.mi)
            (target === nothing || target.return_type === Any) || (ctx.ssa_types[i] = target.return_type)
        end
    end
    # Allocate locals for multi-use SSAs. These passes run before
    # any statement is compiled, so a failure inside them is attributed to the FUNCTION
    # (the statement entry, L119, cannot see it) — never a bare error naming no site.
    try
        numeric_joins = analyze_control_flow!(ctx)  # loops, phi locals, the numeric joins
        analyze_signal_captures!(ctx)  # Identify SSAs that are signal getters/setters
        allocate_slot_locals!(ctx)  # Slot locals BEFORE SSA locals (no overlap)
        allocate_ssa_locals!(ctx, numeric_joins)
        allocate_memoryref_offset_locals!(ctx)
        allocate_scratch_locals!(ctx)  # Extra locals for complex operations
    catch e
        (e isa WasmCompileError || e isa WasmInternalError) && rethrow()
        throw(WasmInternalError(_ctx_func_name(ctx), 0, "", String[], e,
                                _raised_frames(catch_backtrace(), :CompilationContext)))
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
parity(quarantine: WT's JS-interop signals (WasmGlobal, Therapy): a captured signal is a wasm global the host reads; dart's JS interop has no such capture.)
"""
function analyze_signal_captures!(ctx::AbstractCompilationContext)::Nothing
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
    allocate_string_scratch!(ctx) -> Nothing

The five scratch locals a String comparison uses (a result ref, two source refs, two i32
counters), stored in ctx.scratch_locals: allocated up front when the function's types name a
String or Symbol, or at the first comparison that needs them (two String literals compared in
a function no String type names).
parity(quarantine: WT compares two Strings byte by byte in scratch locals; dart's String ==
is a method call, string_patch.dart.)
"""
function allocate_string_scratch!(ctx::AbstractCompilationContext)::Nothing
    # Add 5 scratch locals for string operations:
    # - 1 ref for result array
    # - 2 refs for source strings
    # - 2 i32s for lengths/indices
    # Use get_string_array_type! to ensure type is registered
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    str_ref_type = ConcreteRef(str_type_idx, true)

    result_local = allocate_local!(ctx, str_ref_type)   # ref for result
    str1_local = allocate_local!(ctx, str_ref_type)     # ref for str1
    str2_local = allocate_local!(ctx, str_ref_type)     # ref for str2
    len1_local = allocate_local!(ctx, I32)              # i32 for len1
    i_local = allocate_local!(ctx, I32)                 # i32 for len2/index

    # Store the indices in context
    ctx.scratch_locals = (result_local, str1_local, str2_local, len1_local, i_local)
    return nothing
end

"""
Allocate scratch locals for complex operations like string concatenation.
These are extra locals beyond what SSA analysis requires.
Stores the indices in ctx.scratch_locals for later use.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:382 InstructionsBuilder.addLocal)
"""
function allocate_scratch_locals!(ctx::AbstractCompilationContext)::Nothing
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

    needs_string_scratch && allocate_string_scratch!(ctx)
    return nothing
end

"""
    allocate_local!(ctx, julia_type) -> local_index

Allocate a new local variable of the given Julia type and return its index.
The index is relative to the function's locals, accounting for parameters.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:382 InstructionsBuilder.addLocal)
"""
allocate_local!(ctx::AbstractCompilationContext, T::Type)::Int =
    allocate_local!(ctx, get_concrete_wasm_type(T, ctx.mod, ctx.type_registry; for_local=true))

# the function's one declaration path (declare_local!, builder_add_local!'s)
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:382 InstructionsBuilder.addLocal)
allocate_local!(ctx::AbstractCompilationContext, wasm_type::WasmValType)::Int =
    declare_local!(ctx.mod, ctx.locals, ctx.n_params, wasm_type)

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:382 InstructionsBuilder.addLocal)
function boxing_scratch_local!(ctx::AbstractCompilationContext,
                               wasm_type::WasmValType)::Int
    get!(ctx.boxing_scratch_locals, wasm_type) do
        allocate_local!(ctx, wasm_type)
    end
end

"""
Convert a numeric value on the stack to f64 (no-op when already f64) — builder-native
(THE implementation). Used for DOM bindings where numerics pass as f64 for JS.
parity(quarantine: WT's JS-interop signals (WasmGlobal, Therapy): a captured signal is a wasm global the host reads; dart's JS interop has no such capture.)
"""
function emit_convert_to_f64!(b::InstrBuilder, valtype::WasmValType)::InstrBuilder
    if valtype == I32
        num!(b, 0xB7)  # f64.convert_i32_s
    elseif valtype == I64
        num!(b, 0xB9)  # f64.convert_i64_s
    elseif valtype == F32
        num!(b, 0xBB)  # f64.promote_f32
    end
    return b
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
function refine_checked_cast_types!(ctx::AbstractCompilationContext)::Nothing
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
        value_type(ctx, _cx) === _cT || continue
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
                                :eq_float, :ne_float, :lt_float, :le_float, :fpiseq)

# A field read: `getfield` itself, or a `getproperty` (Base's, or the Compiler's own), which
# Julia lowers a field read through.
# parity(quarantine: Julia's getproperty → getfield lowering — Kernel's InstanceGet is one node.)
_is_getfield_callee(@nospecialize(f))::Bool =
    f === Core.getfield || f === Base.getproperty || f === Core.Compiler.getproperty

"""
    numeric_local_joins(ctx) -> Dict{Int,Type}

The joins of the function being compiled: Julia leaves a scalar-replaced `Core.Box`
accumulator and its phis typed `Any`, and the reads of a captured box `Any`; each join is the
one type such an SSA carries, so its local is that type (NumericJoin.tla, CaptureType.tla,
BoxValueTypes.tla). Collection computed them once (plan_joins); codegen reads them and runs no
analysis and no inference of its own. A body the plan does not hold has none.
parity(translator.dart:2100 Translator.translateTypeOfLocalVariable): a variable's local is
typed by its real inferred type, not the erased one.
"""
numeric_local_joins(ctx::AbstractCompilationContext)::Dict{Int,Type} =
    ctx.mi === nothing ? Dict{Int,Type}() : plan_joins(ctx.translator.plan, ctx.mi)

"""
Analyze control flow to find loops and handle phi nodes.
parity(quarantine: Julia's IR is a CFG of gotos; WT recovers its loops and phis, where dart's kernel tree carries its structure (dev/formal/Stackifier.tla).)
"""
function analyze_control_flow!(ctx::AbstractCompilationContext)::Dict{Int,Type}
    nir = ctx.nir

    # The numeric joins, computed once (numeric_local_joins): they type the phi locals below
    # and the SSA locals in allocate_ssa_locals!, and each refines an erased (Any or Union)
    # SSA type so every consumer sees the proven type.
    _numeric_joins = numeric_local_joins(ctx)
    for (_jk, _jv) in _numeric_joins
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
            # An Any-typed SSA has no ssa_types entry, and a phi typed Any
            # maps to a reference, not I64: inference's own type is the fallback.
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
                nothing : boundary_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
            is_func_ret_numeric = func_ret_wasm === I32 || func_ret_wasm === I64 ||
                                  func_ret_wasm === F32 || func_ret_wasm === F64
            is_phi_ref = phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef ||
                         phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef ||
                         phi_wasm_type === ExternRef || phi_wasm_type === EqRef

            if is_func_ret_numeric && is_phi_ref
                # Check if this phi is used in a ReturnNode
                phi_used_in_return = any(ssa_users(ctx, i)) do j
                    nir[j].node isa NirReturn && nir[j].node.value isa NirSSA &&
                        nir[j].node.value.id == i
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
            is_wasm_struct_numeric = _julia_int_width(phi_julia_type, false) == 128
            if is_phi_any_ref && !is_wasm_struct_numeric
                for j in ssa_users(ctx, i)   # the statements that use the phi
                    use_rec = nir[j]
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

            local_idx = allocate_local!(ctx, phi_wasm_type)
            # Trace externref phi allocations
            if get(ENV, "WASMTARGET_DEBUG_LOCALS", "") == "1"
                n_stmts = length(nir)
                @warn "ALLOC PHI local $local_idx type=$(phi_wasm_type) for SSA $i (stmts=$n_stmts, n_params=$(ctx.n_params))" maxlog=200
            end
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
            local_idx = allocate_local!(ctx, phic_wasm_type)
            ctx.phi_locals[i] = local_idx
        end
    end
    return _numeric_joins
end

"""
Allocate locals for SSA values that need them.
We need locals when:
1. An SSA value is used multiple times
2. An SSA value is not used immediately (intervening stack operations)
3. An SSA value is used in a multi-arg call where a sibling arg has a local
4. An SSA value is defined inside a loop but used outside (e.g., in return)
parity(quarantine: Julia's IR is SSA; each value a statement reads from elsewhere gets a local, where dart's variables are declared locals.)
"""
function allocate_ssa_locals!(ctx::AbstractCompilationContext,
                             _numeric_joins::Dict{Int,Type})::Nothing
    nir = ctx.nir
    refine_checked_cast_types!(ctx)   # parity(code_generator.dart:3170 CodeGenerator.visitAsExpression): dart `as T` — see the helper

    # Count uses of each SSA value
    ssa_uses = Dict{Int, Int}()
    for rec in nir
        count_ssa_uses!(rec, ssa_uses)
    end

    _is_jump(k) = nir[k].node isa NirGoto || nir[k].node isa NirGotoIfNot

    # First pass: allocate locals for SSAs used more than once or with intervening ops
    needs_local_set = Set{Int}()
    q = _LocalQueryIndex(ctx)
    _jump_between(a, b) = _count_between(q.jumps, a, b) > 0

    # Find SSAs defined inside a loop but used outside
    # These need locals because stack values don't persist across Wasm block boundaries
    for (header, back_edge) in q.loops
        for i in max(header, 1):min(back_edge, length(nir))
            # SSA i is defined inside this loop; its last use (in a return or any other
            # statement) after the loop needs a local
            u = ssa_users(ctx, i)
            !isempty(u) && u[end] > back_edge && push!(needs_local_set, i)
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
            if _jump_between(val_id + 1, i - 1)
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
            # Control flow between this PiNode and a later non-phi use needs a local; the
            # last such use spans every earlier one
            last_use = 0
            for j in ssa_users(ctx, i)
                j > i && !(nir[j].node isa NirPhi) && (last_use = j)
            end
            last_use > 0 && _jump_between(i + 1, last_use - 1) && push!(needs_local_set, i)
        end
    end

    # Find SSA values used across control flow boundaries.
    # In Wasm, stack values don't persist across block/branch boundaries.
    # Any SSA defined before a GotoNode/GotoIfNot and used after it needs a local.
    for (i, rec) in enumerate(nir)
        if produces_stack_value(rec)
            # Control flow between the definition and a later use; the last use spans them all
            u = ssa_users(ctx, i)
            !isempty(u) && u[end] > i && _jump_between(i + 1, u[end] - 1) && push!(needs_local_set, i)
        end
    end

    # a traced compile's traced function keeps each statement of a traced type in a local,
    # which the probe after its store reads (emit_statement_trace!)
    if _trace_id(ctx) !== nothing
        for (i, rec) in enumerate(nir)
            rec.slot == 0 && produces_stack_value(rec) && !(rec.node isa NirPhi) &&
                haskey(TRACED_STATEMENT_TYPES, get(ctx.ssa_types, i, Any)) && push!(needs_local_set, i)
        end
    end

    for (ssa_id, use_count) in ssa_uses
        if haskey(ctx.phi_locals, ssa_id)
            # Phi nodes already have locals
            ctx.ssa_locals[ssa_id] = ctx.phi_locals[ssa_id]
        elseif use_count > 1 || needs_local(ctx, ssa_id, q)
            push!(needs_local_set, ssa_id)
        end
    end

    # Second pass: ALL SSA args in calls/invokes/new/return/GotoIfNot need locals.
    # In Wasm, we can't rely on stack values being available because the stackified
    # flow generator may insert block boundaries between the SSA definition and its use.
    for rec in nir
        node = rec.node
        # All SSA values a statement lists directly need locals, and so do the operands of the
        # IR node kinds (a return's value, a branch condition, a pi's source, an upsilon's
        # value: the one operand table's); a phi's and a PhiC's are their edges', above
        for arg in nir_direct_operands(rec)
            arg isa NirSSA && push!(needs_local_set, arg.id)
        end
        if !_nir_from_expr(node) && !(node isa NirPhi || node isa NirPhiC)
            _nir_any_operand(x -> (x isa NirSSA && push!(needs_local_set, x.id); false), node)
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
                ssa_type = value_type(ctx, arg)
                is_numeric = exact_register(ssa_type) !== nothing
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
                inner_type = value_type(ctx, inner_val)
                if inner_type !== Any && inner_type !== Union{}
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

            # :the_exception produces anyref, the top entry's exception (emit_current_exception!).
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

            # a primitive wider than every register that is no 128-bit integer has no
            # representation (numeric_register answers none): it rejects at its statement
            if ssa_type isa DataType && isprimitivetype(ssa_type) && numeric_register(ssa_type) === nothing &&
               _julia_int_width(ssa_type, false) != 128
                record_unsupported!(ctx, :unsupported_type,
                    "a $(sizeof(ssa_type))-byte primitive $(ssa_type) has no representation: no register holds it, and it is no Int128 or UInt128";
                    idx=ssa_id)
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
                    if node.value isa NirArgument || node.value isa NirSSA
                        # a Union source held as anyref: keep effective_type = ssa_type (the narrowed target)
                        local _pi_src_type = value_type(ctx, node.value)
                        _pi_src_is_anyref = _pi_src_type isa Union && needs_anyref_boxing(_pi_src_type)
                    end
                    if !_pi_src_is_anyref
                        # Non-Union source: use source type for compatible locals (an SSA
                        # Julia left `Any` keeps the narrowed target)
                        if node.value isa NirSSA
                            local _src_t = value_type(ctx, node.value)
                            _src_t === Any || (effective_type = _src_t)
                        elseif node.value isa NirArgument
                            effective_type = value_type(ctx, node.value)
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
                    obj_type = value_type(ctx, obj_arg)
                    if obj_type isa DataType && isstructtype(obj_type) && !isprimitivetype(obj_type)
                        field_sym = field_ref isa NirLiteral ? field_ref.value : field_ref
                        if field_sym isa Symbol && hasfield(obj_type, field_sym)
                            jft = fieldtype(obj_type, field_sym)
                            if jft === Any
                                wasm_type = AnyRef
                            end
                        end
                    end
                end
                # Also check memoryrefget on Any-element arrays
                if sfunc === Core.memoryrefget
                    ref_arg = call.operands[1]
                    ref_type = value_type(ctx, ref_arg)
                    if ref_type isa DataType
                        elt = nothing
                        if ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1
                            elt = ref_type.parameters[1]
                        elseif ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2
                            elt = ref_type.parameters[2]
                        end
                        if elt === Any
                            wasm_type = AnyRef
                        end
                    end
                end
            end

            # Fix When wasm_type is ExternRef but SSA is used in numeric context,
            # type the local based on the Julia type inference to match the expected operand type.
            # This handles dead code after UNREACHABLE and Any-typed struct fields used in comparisons.
            if wasm_type === ExternRef
                for j in ssa_users(ctx, ssa_id)   # the statements that use the value
                    use_rec = nir[j]
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

            local_idx = allocate_local!(ctx, wasm_type)
            # Trace externref allocations for diagnostics
            if get(ENV, "WASMTARGET_DEBUG_LOCALS", "") == "1"
                n_stmts = length(nir)
                @warn "ALLOC SSA local $local_idx type=$(wasm_type) effective=$(effective_type) ssa_type=$(ssa_type) for SSA $ssa_id (stmts=$n_stmts, n_params=$(ctx.n_params))" maxlog=200
            end
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
parity(quarantine: Julia's slots and flattened vararg packs, read from the IR's slot table; dart's parameters and variables are declared.)
"""
function allocate_slot_locals!(ctx::AbstractCompilationContext)::Nothing
    n_arg_slots = length(ctx.arg_types) + 1  # slot 1 = self, slot 2..n+1 = args

    for (i, rec) in enumerate(ctx.nir)
        slot_id = rec.slot
        if slot_id > n_arg_slots && !haskey(ctx.slot_locals, slot_id)
            # Determine type from the SSA type of this statement
            ssa_type = get(ctx.ssa_types, i, Any)
            wasm_type = get_concrete_wasm_type(ssa_type, ctx.mod, ctx.type_registry; for_local=true)
            local_idx = allocate_local!(ctx, wasm_type)
            ctx.slot_locals[slot_id] = local_idx
        end
    end
end

"""
    _LocalQueryIndex(ctx)

The facts `allocate_ssa_locals!` and `needs_local` ask about every SSA value, computed once
per function instead of rescanning the body per value: running counts of the jumps and of the stack-value producers (a range holds one when
`_count_between` is positive), the loops (loop_bounds), and those whose body branches other
than at its header.
parity(quarantine: WT decides stack residency per Julia SSA value, a question dart2wasm's expression-tree codegen never asks; this indexes the Julia IR once for it.)
"""
struct _LocalQueryIndex
    jumps::Vector{Int}        # jumps[k + 1]: the goto/goto-if-not statements in 1:k
    producers::Vector{Int}    # producers[k + 1]: the statements in 1:k that produce_stack_value
    loops::Vector{Tuple{Int,Int}}            # loop_bounds
    branching_loops::Vector{Tuple{Int,Int}}
end

"""
    loop_bounds(cfg) -> Vector{Tuple{Int,Int}}

Each loop of the body as its header and its last back edge, in header order, read off the one
CFG (nir_cfg): a back edge is a successor block at or before its own block, the header is that
successor's first statement and the latch the last statement of the block the edge leaves (a
backward goto or goto-if-not alike); a header's last back edge is its latest latch. The one
loop-bounds definition, read by the local allocation (a value defined in a loop and used after
it, and a loop that branches inside).
parity(quarantine: Julia's IR is a CFG of gotos; WT recovers its loops, where dart's kernel tree carries its structure (dev/formal/Stackifier.tla).)
"""
function loop_bounds(cfg::NirCFG)::Vector{Tuple{Int,Int}}
    local last_back_edge = Dict{Int,Int}()
    for k in eachindex(cfg.blocks), s in cfg.succs[k]
        s <= k || continue
        local header = cfg.blocks[s].start_idx
        last_back_edge[header] = max(get(last_back_edge, header, 0), cfg.blocks[k].end_idx)
    end
    return sort!(Tuple{Int,Int}[(h, be) for (h, be) in last_back_edge])
end

# parity(quarantine: WT decides stack residency per Julia SSA value, a question dart2wasm's expression-tree codegen never asks; this indexes the Julia IR once for it.)
function _LocalQueryIndex(ctx::AbstractCompilationContext)::_LocalQueryIndex
    nir = ctx.nir
    n = length(nir)
    jumps = zeros(Int, n + 1)
    producers = zeros(Int, n + 1)
    for (k, rec) in enumerate(nir)
        jumps[k + 1] = jumps[k] + (rec.node isa NirGoto || rec.node isa NirGotoIfNot)
        producers[k + 1] = producers[k] + produces_stack_value(rec)
    end
    local loops = loop_bounds(ctx.cfg)
    branching_loops = Tuple{Int,Int}[]
    for (header, back_edge) in loops
        # a conditional in the loop other than its exit test at the header
        any(i -> nir[i].node isa NirGotoIfNot && i != header && i != header + 1, header:back_edge) &&
            push!(branching_loops, (header, back_edge))
    end
    return _LocalQueryIndex(jumps, producers, loops, branching_loops)
end

# the statements that use SSA `id`, ascending
# parity(quarantine: SSA use query by id, the NirSSA case of nir_uses.)
ssa_users(ctx::AbstractCompilationContext, id::Int)::Vector{Int} = get(ctx.ssa_users, id, Int[])

# how many of statements a:b a running count counts (0 for an empty range)
# parity(quarantine: WT decides stack residency per Julia SSA value, a question dart2wasm's expression-tree codegen never asks; this indexes the Julia IR once for it.)
function _count_between(counts::Vector{Int}, a::Int, b::Int)::Int
    a = max(a, 1)
    b = min(b, length(counts) - 1)
    return a <= b ? counts[b + 1] - counts[a] : 0
end

"""
Check if an SSA value needs a local (e.g., not used immediately or used after other stack-producing operations).
parity(quarantine: Julia's IR is SSA; each value a statement reads from elsewhere gets a local, where dart's variables are declared locals.)
"""
function needs_local(ctx::AbstractCompilationContext, ssa_id::Int, q::_LocalQueryIndex)::Bool
    nir = ctx.nir
    _first_use(id) = (for j in ssa_users(ctx, id); j != id && return j; end; nothing)

    # Find where this SSA is used
    use_idx = _first_use(ssa_id)

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
            next_use = _first_use(actual_use_idx)
            if next_use !== nothing
                actual_use_idx = next_use
                continue
            end
        end
        break
    end

    # If there are any statements between definition and use that produce values,
    # we need a local because those values will mess up the stack
    _count_between(q.producers, ssa_id + 1, actual_use_idx - 1) > 0 && return true

    # Also need local if there's control flow between definition and use
    _count_between(q.jumps, ssa_id + 1, actual_use_idx - 1) > 0 && return true

    # If SSA is defined inside a loop and there are conditionals in the loop,
    # we need a local to ensure stack balance across control flow
    return any(((header, back_edge),) -> header <= ssa_id <= back_edge, q.branching_loops)
end

"""
Check if a statement produces a value on the stack: a call, invoke, `%new`, boundscheck,
exception read, phi or pi, or a statement that is itself a value. An assignment into a
slot stores its value instead.
parity(quarantine: Julia's IR is SSA; each value a statement reads from elsewhere gets a local, where dart's variables are declared locals.)
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
parity(quarantine: Julia's IR is SSA; each value a statement reads from elsewhere gets a local, where dart's variables are declared locals.)
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
Count the SSA uses one statement makes, each operand once per position: the operands the one
operand table names (`_nir_any_operand`: an expression's operands and dynamic callee, a return's
value, a branch condition, a phi's, a PhiC's and an upsilon's values, a pi's source, ...). A
statement that is itself an SSA value (or a slot assigned from one) is a use.
parity(quarantine: Julia's IR is SSA; each value a statement reads from elsewhere gets a local, where dart's variables are declared locals.)
"""
function count_ssa_uses!(rec::NirStmt, uses::Dict{Int, Int})::Nothing
    _count(x) = (x isa NirSSA && (uses[x.id] = get(uses, x.id, 0) + 1); false)
    _count(rec.node)
    _nir_any_operand(_count, rec.node)
    return nothing
end

"""Return the source tuple type when one IR argument is a flattened vararg pack.

`CodeInfo` exposes a vararg method's final source argument as `Tuple{...}`, while
the Wasm function signature contains each concrete vararg as a separate physical
parameter. An ordinary tuple argument has one matching physical tuple parameter
and is deliberately not classified as a pack.
parity(quarantine: Julia's slots and flattened vararg packs, read from the IR's slot table; dart's parameters and variables are declared.)
"""
function packed_vararg_source_type(ctx::AbstractCompilationContext,
                                   source_slot::Integer,
                                   physical_start::Integer)::Union{Type, Nothing}
    1 <= source_slot <= length(ctx.slot_types) || return nothing
    T = value_type(ctx, NirArgument(source_slot))
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

"""
    value_type(node, slot_types, ssa_types) -> Type
    value_type(ctx, node) -> Type

The Julia type of an operand node, Julia's own answer for it: Compiler's `argextype`
(optimize.jl:423 on 1.12.7, :502 on 1.13.1), widened as the NIR boundary widens every type.
- An SSA value: its statement's type, `ssa_types[id]` (in codegen `ctx.ssa_types`, the
  boundary's type plus the plan's joins; in collection the body's joins), else, and when
  `ssa_types` is `nothing`, the type the boundary recorded on the node.
- An argument or a slot: its slot type (`CodeInfo.slottypes`, widened at the boundary); `Any`
  with no slot table (`slot_types` is `nothing`), and one outside the table is invalid IR
  (argextype's InvalidIRError).
- A literal (a QuoteNode payload or an embedded constant): `widenconst(Const(v))`,
  `Core.Typeof(v)`.
- A global: the type the boundary read for its binding (NirGlobalRef.julia_type).
Any other node is not an operand. This is the one reader of an operand's Julia type (L174):
collection and codegen both read it.
parity(code_generator.dart:129 CodeGenerator.dartTypeOf): one function answers every node's type.
"""
function value_type(node::NirNode, slot_types::Union{Nothing,AbstractVector}, ssa_types)::Type
    if node isa NirSSA
        return ssa_types === nothing ? node.julia_type : get(ssa_types, node.id, node.julia_type)
    elseif node isa NirArgument || node isa NirSlot
        slot_types === nothing && return Any
        local n = node isa NirArgument ? node.n : node.id
        1 <= n <= length(slot_types) ||
            error("$(node) is outside the slot table ($(length(slot_types)) slots): invalid IR")
        return slot_types[n]
    elseif node isa NirLiteral
        return Core.Typeof(node.value)
    elseif node isa NirGlobalRef
        return node.julia_type
    end
    error("value_type of $(node), which is not an operand")
end
# parity(code_generator.dart:129 CodeGenerator.dartTypeOf): the same reader over the function being compiled.
value_type(ctx::AbstractCompilationContext, node::NirNode)::Type =
    value_type(node, ctx.slot_types, ctx.ssa_types)

"""
    _ref_cast_source_type(val, ctx)

Resolve the DECLARED wasm slot type of `val`'s source (SSA/phi local or parameter) —
feeds emit_ref_cast_if_structref!: when the source slot is abstract (structref/anyref)
or a mismatched concrete ref, a `ref.cast null \$target` narrows it for struct_get.
parity(pkg/dart2wasm/lib/translator.dart:1597 Translator.convertType)
"""
function _ref_cast_source_type(val::NirNode, ctx::AbstractCompilationContext)::Union{Nothing, WasmValType}
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

"""builder-native form: resolve the source's declared wasm type and narrow on `b`.
parity(pkg/dart2wasm/lib/translator.dart:1597 Translator.convertType)"""
function emit_ref_cast_if_structref!(b::InstrBuilder, val, target_type_idx::Integer, ctx::AbstractCompilationContext)::InstrBuilder
    _emit_ref_cast_arm!(b, _ref_cast_source_type(val, ctx), target_type_idx)
    return b
end

"""builder-native core: with the source ref on `b`'s stack, narrow per the arm table.
parity(pkg/dart2wasm/lib/translator.dart:1597 Translator.convertType)"""
function _emit_ref_cast_arm!(b::InstrBuilder, local_wasm_type::Union{Nothing, WasmValType},
                            target_type_idx::Integer)::InstrBuilder
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
    narrowed_local_type(ctx, local_idx, ssa_id) -> Union{WasmValType,Nothing}

The type a read of SSA `ssa_id` from its local `local_idx` delivers when the local is
generic (anyref/structref/externref/eqref) and the SSA's inferred type is one concrete type:
the struct ref it is cast to (nullable) or the number it is unboxed to. `nothing` when the
read delivers the local as it is. The one rule behind `_narrow_generic_local!`, which emits
the cast or the unbox, and `static_wasm_type`, which answers it before emission.
parity(translator.dart:2100 Translator.translateTypeOfLocalVariable)
"""
function narrowed_local_type(ctx::AbstractCompilationContext, local_idx::Integer,
                             ssa_id::Integer)::Union{WasmValType,Nothing}
    arr_idx = local_idx - ctx.n_params + 1
    (1 <= arr_idx <= length(ctx.locals)) || return nothing
    local_wasm_type = ctx.locals[arr_idx]
    (local_wasm_type === AnyRef || local_wasm_type === StructRef ||
     local_wasm_type === ExternRef || local_wasm_type === EqRef) || return nothing
    ssa_julia_type = get(ctx.ssa_types, ssa_id, Any)
    # A Union{Nothing, T} stays unnarrowed: the value may be nothing, and its narrowing is
    # the PiNode after the null check.
    (ssa_julia_type === Any || ssa_julia_type === Union{} || ssa_julia_type isa Union) &&
        return nothing
    concrete_wasm = get_concrete_wasm_type(ssa_julia_type, ctx.mod, ctx.type_registry)
    concrete_wasm isa ConcreteRef && return ConcreteRef(concrete_wasm.type_idx, true)
    (concrete_wasm === I32 || concrete_wasm === I64 ||
     concrete_wasm === F32 || concrete_wasm === F64) && return concrete_wasm
    return nothing
end

"""
    _narrow_generic_local!(b, local_idx, ssa_id, ctx) -> Bool

builder-native — THE implementation): when a local has generic type
(anyref/structref/externref/eqref) but the SSA's Julia type maps to a concrete Wasm
type (narrowed_local_type), narrow the value on `b`'s stack (`ref.cast null` for refs — a
no-op at runtime when correct, a trap on a real codegen bug — and THE funnel-unbox for
join-refined numerics). Returns false when no narrowing applies.
parity(pkg/dart2wasm/lib/translator.dart:1597 Translator.convertType)
"""
function _narrow_generic_local!(b::InstrBuilder, local_idx::Integer, ssa_id::Integer, ctx::AbstractCompilationContext)::Bool
    local narrowed = narrowed_local_type(ctx, local_idx, ssa_id)
    narrowed === nothing && return false
    if narrowed isa ConcreteRef
        # ExternRef needs any_convert_extern before ref.cast
        ctx.locals[local_idx - ctx.n_params + 1] === ExternRef && any_convert_extern!(b)
        ref_cast!(b, Int64(narrowed.type_idx), true)
    else
        # parity(translator.dart:1597 Translator.convertType): a join-typed NUMERIC riding a ref local UNBOXES through the ONE
        # funnel (dart convertType) — symmetric to the store-side box. Without this,
        # consumers read a raw box ref where the numeric is expected.
        coerce_stack_top!(b, narrowed, ctx; from_julia=get(ctx.ssa_types, ssa_id, Any))
    end
    return true
end

"""
Extract the global index from a WasmGlobal type.
The index is stored as a type parameter, so we extract it from the type.
parity(quarantine: WT's JS-interop signals (WasmGlobal, Therapy): a captured signal is a wasm global the host reads; dart's JS interop has no such capture.)
"""
function get_wasm_global_idx(val, ctx::AbstractCompilationContext)::Union{Int, Nothing}
    val_type = value_type(ctx, val)
    if val_type <: WasmGlobal
        # Extract IDX from WasmGlobal{T, IDX}
        return global_index(val_type)
    end
    return nothing
end

# ============================================================================
