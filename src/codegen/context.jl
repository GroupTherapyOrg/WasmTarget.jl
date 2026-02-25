# ============================================================================
# Compilation Context
# ============================================================================

"""
Tracks state during compilation of a single function.
"""
mutable struct CompilationContext
    code_info::Core.CodeInfo
    arg_types::Tuple
    return_type::Type
    n_params::Int
    locals::Vector{WasmValType}  # Additional locals beyond params (supports refs)
    ssa_types::Dict{Int, Type}   # SSA value -> Julia type
    ssa_locals::Dict{Int, Int}   # SSA value -> local index (for multi-use SSAs)
    phi_locals::Dict{Int, Int}   # PhiNode SSA -> local index
    loop_headers::Set{Int}       # Line numbers that are loop headers (targets of backward jumps)
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
    # DOM bindings for Therapy.jl - emit DOM update calls after signal writes
    # Maps global_idx -> [(import_idx, [hk_arg, ...]), ...]
    dom_bindings::Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}
    # Module-level globals: maps (Module, Symbol) -> Wasm global index
    # Used for const mutable struct instances that should be shared across functions
    module_globals::Dict{Tuple{Module, Symbol}, UInt32}
    # Scratch local indices for string operations (fixed at allocation time)
    # Tuple of (result_local, str1_local, str2_local, len1_local, i_local) or nothing
    scratch_locals::Union{Nothing, NTuple{5, Int}}
    # MemoryRef offset tracking: maps SSA id -> index SSA/value for memoryrefnew(ref, index, bc)
    # Used by memoryrefoffset to get the offset. Fresh refs (not in this map) have offset 1.
    memoryref_offsets::Dict{Int, Any}
    # Stack validator: tracks value stack types during bytecode emission (PURE-414)
    # Advisory only — warns on type mismatches but doesn't prevent compilation
    validator::WasmStackValidator
    # PURE-908: Set true by compile_call/compile_invoke when a stub emits UNREACHABLE.
    # compile_statement reads and resets this to skip LOCAL_SET in dead code.
    last_stmt_was_stub::Bool
    # PURE-6024: Slot variable locals for unoptimized IR (may_optimize=false).
    # Maps SlotNumber.id -> WASM local index. Slot 1 = self, Slot 2 = arg1, etc.
    # Slots > n_params+1 are local variables assigned with Expr(:(=), SlotNumber, rhs).
    slot_locals::Dict{Int, Int}
end

function CompilationContext(code_info, arg_types::Tuple, return_type, mod::WasmModule, type_registry::TypeRegistry;
                           func_registry::Union{FunctionRegistry, Nothing}=nothing,
                           func_idx::UInt32=UInt32(0), func_ref=nothing,
                           global_args::Set{Int}=Set{Int}(),
                           is_compiled_closure::Bool=false,
                           captured_signal_fields::Dict{Symbol, Tuple{Bool, UInt32}}=Dict{Symbol, Tuple{Bool, UInt32}}(),
                           dom_bindings::Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}=Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}(),
                           module_globals::Dict{Tuple{Module, Symbol}, UInt32}=Dict{Tuple{Module, Symbol}, UInt32}())
    # Calculate n_params excluding WasmGlobal arguments (they're phantom)
    n_real_params = count(i -> !(i in global_args), 1:length(arg_types))
    ctx = CompilationContext(
        code_info,
        arg_types,
        return_type,
        n_real_params,
        WasmValType[],
        Dict{Int, Type}(),
        Dict{Int, Int}(),
        Dict{Int, Int}(),
        Set{Int}(),
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
        dom_bindings,           # DOM bindings for Therapy.jl
        module_globals,         # Module-level globals (const mutable structs)
        nothing,                # scratch_locals (set by allocate_scratch_locals!)
        Dict{Int, Any}(),       # memoryref_offsets (populated during compilation)
        WasmStackValidator(enabled=true, func_name="func_$(func_idx)"),  # PURE-414: stack validator
        false,                  # last_stmt_was_stub (PURE-908)
        Dict{Int, Int}()        # slot_locals (PURE-6024: unoptimized IR slot variables)
    )
    # Analyze SSA types and allocate locals for multi-use SSAs
    analyze_ssa_types!(ctx)
    analyze_control_flow!(ctx)  # Find loops and phi nodes
    analyze_signal_captures!(ctx)  # Identify SSAs that are signal getters/setters
    allocate_slot_locals!(ctx)  # PURE-6024: Slot locals BEFORE SSA locals (no overlap)
    allocate_ssa_locals!(ctx)
    allocate_scratch_locals!(ctx)  # Extra locals for complex operations
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
function analyze_signal_captures!(ctx::CompilationContext)
    isempty(ctx.captured_signal_fields) && return

    code = ctx.code_info.code

    # For Therapy.jl: captured signal fields are getter/setter FUNCTIONS (closures)
    # When we see getfield(_1, :count) where :count is a getter, the resulting SSA
    # is a function that when invoked returns the signal value.
    # We directly map these to signal_ssa_getters/setters so that when compile_invoke
    # sees invoke(%ssa), it knows to emit global.get/global.set.

    # First pass: find closure field accesses to signal getter/setter functions
    for (i, stmt) in enumerate(code)
        if stmt isa Expr && stmt.head === :call
            func = stmt.args[1]
            # Handle both Core.getfield and Base.getfield
            is_getfield = (func isa GlobalRef &&
                          ((func.mod === Core && func.name === :getfield) ||
                           (func.mod === Base && func.name === :getfield)))
            if is_getfield && length(stmt.args) >= 3
                target = stmt.args[2]
                field_ref = stmt.args[3]
                field_name = field_ref isa QuoteNode ? field_ref.value : field_ref

                # Check if this is getfield(_1, :fieldname) - getting captured closure field
                # Target can be Core.SlotNumber(1) or Core.Argument(1)
                is_closure_self = (target isa Core.SlotNumber && target.id == 1) ||
                                  (target isa Core.Argument && target.n == 1)
                if is_closure_self
                    if field_name isa Symbol && haskey(ctx.captured_signal_fields, field_name)
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
            end
        end
    end

    # Also handle WasmGlobal-style patterns (for compatibility with WasmGlobal{T, IDX})
    # Track CompilableSignal/CompilableSetter SSAs
    compilable_ssas = Dict{Int, Tuple{Bool, UInt32}}()  # ssa -> (is_getter, global_idx)

    # Track Signal SSAs (from getfield(CompilableSignal/Setter, :signal))
    signal_ssas = Dict{Int, UInt32}()  # ssa -> global_idx

    # Find getfield(_1, :fieldname) that might be WasmGlobal-style
    for (i, stmt) in enumerate(code)
        if stmt isa Expr && stmt.head === :call
            func = stmt.args[1]
            # Handle both Core.getfield and Base.getfield
            is_getfield = (func isa GlobalRef &&
                          ((func.mod === Core && func.name === :getfield) ||
                           (func.mod === Base && func.name === :getfield)))
            if is_getfield && length(stmt.args) >= 3
                target = stmt.args[2]
                field_ref = stmt.args[3]
                field_name = field_ref isa QuoteNode ? field_ref.value : field_ref

                is_closure_self = (target isa Core.SlotNumber && target.id == 1) ||
                                  (target isa Core.Argument && target.n == 1)
                if is_closure_self
                    if field_name isa Symbol && haskey(ctx.captured_signal_fields, field_name)
                        is_getter, global_idx = ctx.captured_signal_fields[field_name]
                        compilable_ssas[i] = (is_getter, global_idx)
                    end
                end
            end
        end
    end

    # Find getfield(CompilableSignal/Setter, :signal) -> Signal
    for (i, stmt) in enumerate(code)
        if stmt isa Expr && stmt.head === :call
            func = stmt.args[1]
            is_getfield = (func isa GlobalRef &&
                          ((func.mod === Core && func.name === :getfield) ||
                           (func.mod === Base && func.name === :getfield)))
            if is_getfield && length(stmt.args) >= 3
                target = stmt.args[2]
                field_ref = stmt.args[3]
                field_name = field_ref isa QuoteNode ? field_ref.value : field_ref

                if target isa Core.SSAValue && field_name === :signal
                    if haskey(compilable_ssas, target.id)
                        _, global_idx = compilable_ssas[target.id]
                        signal_ssas[i] = global_idx
                    end
                end
            end
        end
    end

    # Mark getfield(Signal, :value) as signal reads
    # and setfield!(Signal, :value, x) as signal writes
    for (i, stmt) in enumerate(code)
        if stmt isa Expr && stmt.head === :call
            func = stmt.args[1]

            # Handle getfield(Signal, :value) -> signal read
            is_getfield = (func isa GlobalRef &&
                          ((func.mod === Core && func.name === :getfield) ||
                           (func.mod === Base && func.name === :getfield)))
            if is_getfield && length(stmt.args) >= 3
                target = stmt.args[2]
                field_ref = stmt.args[3]
                field_name = field_ref isa QuoteNode ? field_ref.value : field_ref

                if target isa Core.SSAValue && field_name === :value
                    if haskey(signal_ssas, target.id)
                        global_idx = signal_ssas[target.id]
                        ctx.signal_ssa_getters[i] = global_idx
                    end
                end
            end

            # Handle setfield!(Signal, :value, x) -> signal write
            is_setfield = (func isa GlobalRef &&
                          ((func.mod === Core && func.name === :setfield!) ||
                           (func.mod === Base && func.name === :setfield!)))
            if is_setfield && length(stmt.args) >= 4
                target = stmt.args[2]
                field_ref = stmt.args[3]
                new_value = stmt.args[4]
                field_name = field_ref isa QuoteNode ? field_ref.value : field_ref

                if target isa Core.SSAValue && field_name === :value
                    if haskey(signal_ssas, target.id)
                        global_idx = signal_ssas[target.id]
                        ctx.signal_ssa_setters[i] = global_idx
                    end
                end
            end
        end
    end
end

"""
Allocate scratch locals for complex operations like string concatenation.
These are extra locals beyond what SSA analysis requires.
Stores the indices in ctx.scratch_locals for later use.
"""
function allocate_scratch_locals!(ctx::CompilationContext)
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
function allocate_local!(ctx::CompilationContext, T::Type)::Int
    wasm_type = julia_to_wasm_type_concrete(T, ctx)
    local_idx = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, wasm_type)
    return local_idx
end

function allocate_local!(ctx::CompilationContext, wasm_type::WasmValType)::Int
    local_idx = ctx.n_params + length(ctx.locals)
    # PURE-908: normalize AnyRef → ExternRef to avoid type hierarchy mismatches
    push!(ctx.locals, wasm_type === AnyRef ? ExternRef : wasm_type)
    return local_idx
end

"""
Convert a Julia type to a WasmValType, using concrete references for struct/array types.
This is like `julia_to_wasm_type` but returns `ConcreteRef` for registered types.
"""
function julia_to_wasm_type_concrete(T, ctx::CompilationContext)::WasmValType
    # Vararg is a type modifier, not a proper type
    # PURE-908: Use ExternRef instead of AnyRef for locals to avoid externref↔anyref
    # mismatches. In WasmGC, anyref and externref are separate type hierarchies.
    # Since Any→ExternRef and cross-calls return ExternRef, locals must be ExternRef.
    if T isa Core.TypeofVararg
        return ExternRef
    end
    # PURE-4155: Type{X} singleton values (e.g., Type{Int64}) are represented as DataType
    # struct refs via global.get. Only match SINGLETON types (not struct types like Union/DataType).
    if T isa DataType && T <: Type && !(T isa UnionAll) && !isstructtype(T)
        info = register_struct_type!(ctx.mod, ctx.type_registry, DataType)
        return ConcreteRef(info.wasm_type_idx, true)
    end
    # Union{} (TypeofBottom) is the bottom type — no values exist of this type.
    # Used for unreachable code paths. Map to I32 as placeholder.
    if T === Union{}
        return I32
    elseif T === String || T === Symbol
        # Strings and Symbols are WasmGC arrays of bytes (not structs)
        type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        return ConcreteRef(type_idx, true)
    elseif T isa DataType && (T.name.name === :MemoryRef || T.name.name === :GenericMemoryRef)
        # MemoryRef{T} maps to array type for element T
        elem_type = T.name.name === :GenericMemoryRef ? T.parameters[2] : T.parameters[1]
        type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
        return ConcreteRef(type_idx, true)
    elseif T isa UnionAll && T <: Base.GenericMemoryRef
        # PURE-902: Bare MemoryRef or constrained MemoryRef{T} where T<:X (UnionAll)
        # This happens when cross-function calls use Vector (no eltype).
        # Try to extract element type from the type variable bound, else use Any.
        local memref_elem_type = Any
        if T isa UnionAll && T.var isa TypeVar && T.var.ub !== Any
            memref_elem_type = T.var.ub
        end
        type_idx = get_array_type!(ctx.mod, ctx.type_registry, memref_elem_type)
        return ConcreteRef(type_idx, true)
    elseif T isa DataType && (T.name.name === :Memory || T.name.name === :GenericMemory)
        # Memory{T} maps to array type for element T
        elem_type = T.parameters[2]
        type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
        return ConcreteRef(type_idx, true)
    elseif is_struct_type(T)
        # If struct is registered, return a ConcreteRef
        if haskey(ctx.type_registry.structs, T)
            info = ctx.type_registry.structs[T]
            return ConcreteRef(info.wasm_type_idx, true)
        else
            # Register it now
            register_struct_type!(ctx.mod, ctx.type_registry, T)
            if haskey(ctx.type_registry.structs, T)
                info = ctx.type_registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            end
        end
        # Fallback to abstract StructRef
        return StructRef
    elseif T <: Tuple
        # PURE-6025: UnionAll tuples (e.g., Tuple{T, T} where T<:Type) lack .parameters.
        # Skip registration and fall through to StructRef.
        if T isa UnionAll
            return StructRef
        end
        # Tuples are stored as WasmGC structs
        if haskey(ctx.type_registry.structs, T)
            info = ctx.type_registry.structs[T]
            return ConcreteRef(info.wasm_type_idx, true)
        else
            # Register it now
            register_tuple_type!(ctx.mod, ctx.type_registry, T)
            if haskey(ctx.type_registry.structs, T)
                info = ctx.type_registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            end
        end
        # Fallback to abstract StructRef
        return StructRef
    elseif T isa DataType && (T.name.name === :MemoryRef || T.name.name === :GenericMemoryRef)
        # MemoryRef{T} / GenericMemoryRef maps to the array type for element T
        # This is Julia's internal type for array element access
        # IMPORTANT: Check this BEFORE AbstractArray since MemoryRef <: AbstractArray
        # GenericMemoryRef parameters: (atomicity, element_type, addrspace)
        elem_type = T.name.name === :GenericMemoryRef ? T.parameters[2] : T.parameters[1]
        if haskey(ctx.type_registry.arrays, elem_type)
            type_idx = ctx.type_registry.arrays[elem_type]
            return ConcreteRef(type_idx, true)
        else
            type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            return ConcreteRef(type_idx, true)
        end
    elseif T isa UnionAll && T <: Base.GenericMemoryRef
        # PURE-902: Bare MemoryRef or constrained MemoryRef{T} where T<:X (UnionAll)
        local memref_elem_type2 = Any
        if T isa UnionAll && T.var isa TypeVar && T.var.ub !== Any
            memref_elem_type2 = T.var.ub
        end
        type_idx = get_array_type!(ctx.mod, ctx.type_registry, memref_elem_type2)
        return ConcreteRef(type_idx, true)
    elseif T isa DataType && (T.name.name === :Memory || T.name.name === :GenericMemory)
        # GenericMemory/Memory is the backing storage for Vector (Julia 1.11+)
        # IMPORTANT: Check this BEFORE AbstractArray since Memory <: AbstractArray
        # Parameters are: (atomicity, element_type, addrspace)
        # In WasmGC, it's the same as the array
        elem_type = T.parameters[2]  # Element type is second parameter
        if haskey(ctx.type_registry.arrays, elem_type)
            type_idx = ctx.type_registry.arrays[elem_type]
            return ConcreteRef(type_idx, true)
        else
            type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)
            return ConcreteRef(type_idx, true)
        end
    elseif T <: AbstractArray  # Handles Vector, Matrix, and higher-dim arrays
        # In Julia 1.11+, Vector is a struct with :ref (MemoryRef) and :size fields
        # Check if the type is registered as a struct first (for Vector/Matrix)
        if haskey(ctx.type_registry.structs, T)
            info = ctx.type_registry.structs[T]
            return ConcreteRef(info.wasm_type_idx, true)
        end

        # 1D arrays (Vector) are stored as WasmGC structs (with ref and size fields)
        if T <: Array
            # Register Vector/Array as a struct type with (ref, size) layout
            info = register_vector_type!(ctx.mod, ctx.type_registry, T)
            return ConcreteRef(info.wasm_type_idx, true)
        elseif T <: AbstractVector && T isa DataType
            # Other AbstractVector types (SubArray, UnitRange, etc.) - register as regular struct
            info = register_struct_type!(ctx.mod, ctx.type_registry, T)
            return ConcreteRef(info.wasm_type_idx, true)
        else
            # Matrix and higher-dim arrays: also stored as structs
            info = register_matrix_type!(ctx.mod, ctx.type_registry, T)
            return ConcreteRef(info.wasm_type_idx, true)
        end
    elseif T === String
        # Strings are WasmGC arrays of bytes
        type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
        return ConcreteRef(type_idx, true)
    elseif T === Int128 || T === UInt128
        # 128-bit integers are represented as WasmGC structs with two i64 fields
        if haskey(ctx.type_registry.structs, T)
            info = ctx.type_registry.structs[T]
            return ConcreteRef(info.wasm_type_idx, true)
        else
            info = register_int128_type!(ctx.mod, ctx.type_registry, T)
            return ConcreteRef(info.wasm_type_idx, true)
        end
    elseif T isa Union
        # Handle Union types
        inner_type = get_nullable_inner_type(T)
        if inner_type !== nothing
            # Union{Nothing, T} -> use T's concrete type (nullable reference)
            return julia_to_wasm_type_concrete(inner_type, ctx)
        else
            # Multi-variant union (2+ non-Nothing types).
            # Check if all non-Nothing variants are numeric (no tagged struct needed).
            types_u = Base.uniontypes(T)
            non_nothing_u = filter(t -> t !== Nothing, types_u)
            all_numeric_u = !isempty(non_nothing_u) && all(non_nothing_u) do t
                wt = julia_to_wasm_type(t)
                wt === I32 || wt === I64 || wt === F32 || wt === F64
            end
            if all_numeric_u
                # Numeric-only union: use widest numeric type (no struct boxing needed).
                # PURE-325: resolve_union_type handles Int128/BigInt/UInt128 unions correctly.
                result = julia_to_wasm_type(T)
                # PURE-908: Never return AnyRef for locals — use ExternRef instead
                return result === AnyRef ? ExternRef : result
            else
                # PURE-6021b: Non-numeric multi-variant union uses a tagged-union struct in WASM.
                # The local must be ConcreteRef to the tagged union type, NOT ExternRef.
                # Using ExternRef causes validation errors: "expected externref, found (ref null $type)"
                # because struct.new $union_type_idx returns ConcreteRef, not externref.
                union_info = get_union_type!(ctx.mod, ctx.type_registry, T)
                return ConcreteRef(union_info.wasm_type_idx, true)
            end
        end
    else
        # Use the standard conversion for non-struct types
        result = julia_to_wasm_type(T)
        # PURE-908: Never return AnyRef for locals — use ExternRef instead
        return result === AnyRef ? ExternRef : result
    end
end

"""
Emit bytecode to convert a value on the stack to f64.
Used for DOM bindings where all numeric values are passed as f64 for JS compatibility.
"""
function emit_convert_to_f64(valtype::WasmValType)::Vector{UInt8}
    if valtype == I32
        return UInt8[0xB7]  # f64.convert_i32_s
    elseif valtype == I64
        return UInt8[0xB9]  # f64.convert_i64_s
    elseif valtype == F32
        return UInt8[0xBB]  # f64.promote_f32
    elseif valtype == F64
        return UInt8[]      # Already f64, no conversion needed
    else
        # For other types (refs, etc.), no conversion - will cause type error
        return UInt8[]
    end
end

"""
Encode a block result type (for if/block/loop).
Handles both simple types (i32/i64/f32/f64) and concrete reference types.
Returns a vector of bytes to append to the instruction stream.
"""
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

"""
Analyze control flow to find loops and handle phi nodes.
"""
function analyze_control_flow!(ctx::CompilationContext)
    code = ctx.code_info.code

    # Find loop headers (targets of backward jumps)
    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode
            target = stmt.label
            if target < i  # Backward jump = loop
                push!(ctx.loop_headers, target)
            end
        elseif stmt isa Core.GotoIfNot
            # GotoIfNot jumps forward (to exit), but check anyway
        end
    end

    # Find goto statements that jump backward (unconditional loop back)
    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode && stmt.label < i
            push!(ctx.loop_headers, stmt.label)
        end
    end

    # Allocate locals for phi nodes (they need to persist across iterations)
    for (i, stmt) in enumerate(code)
        if stmt isa Core.PhiNode
            # PURE-048: Use ssavaluetypes as fallback instead of Int64.
            # analyze_ssa_types! skips Any-typed SSAs, but phi nodes with type Any
            # must map to ExternRef, not I64. Fall back to ssavaluetypes[i] first.
            phi_julia_type = get(ctx.ssa_types, i, nothing)
            if phi_julia_type === nothing
                ssatypes = ctx.code_info.ssavaluetypes
                if ssatypes isa Vector && i <= length(ssatypes)
                    phi_julia_type = ssatypes[i]
                else
                    phi_julia_type = Int64
                end
            end
            phi_wasm_type = julia_to_wasm_type_concrete(phi_julia_type, ctx)

            # PURE-324: For phi nodes with all-numeric Union types (e.g., Union{Int64, UInt32}),
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
                    phi_wasm_type = resolve_union_type(phi_julia_type)
                end
            end

            # Phi locals always use the type derived from the phi's Julia type.
            # Edge type incompatibility is handled downstream by
            # set_phi_locals_for_edge! and the inline phi handler,
            # which emit type-safe defaults for incompatible edges.

            # PURE-036u: If this phi is used directly in a ReturnNode, and the function's
            # Wasm return type is numeric but the phi was allocated as ref, override
            # the phi local's type to match the function's return type.
            # This handles cases like Union{Int64, SomeStruct} phi where Julia type
            # inference produces a tagged union (ref), but the function actually returns i64.
            func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
            is_func_ret_numeric = func_ret_wasm === I32 || func_ret_wasm === I64 ||
                                  func_ret_wasm === F32 || func_ret_wasm === F64
            is_phi_ref = phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef ||
                         phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef ||
                         phi_wasm_type === ExternRef

            if is_func_ret_numeric && is_phi_ref
                # Check if this phi is used in a ReturnNode
                phi_used_in_return = false
                for other_stmt in code
                    if other_stmt isa Core.ReturnNode && isdefined(other_stmt, :val)
                        if other_stmt.val isa Core.SSAValue && other_stmt.val.id == i
                            phi_used_in_return = true
                            break
                        end
                    end
                end
                if phi_used_in_return
                    # Override phi type to match function return type
                    phi_wasm_type = func_ret_wasm
                end
            end

            # PURE-036bg: If phi type is a ref type but used in boolean context (i32_eqz,
            # not_int, eq_int, etc), override to I32. This handles dead code paths where
            # ref-typed phi values are tested with boolean operations.
            # PURE-325: Skip this override for Int128/UInt128 phi types.
            # These are primitive in Julia but map to struct{i64,i64} in Wasm.
            # They're used in comparison ops (sle_int, eq_int) but the phi local must
            # stay as ConcreteRef — the boolean ops receive extracted fields via struct_get.
            is_phi_any_ref = phi_wasm_type isa ConcreteRef || phi_wasm_type === StructRef ||
                             phi_wasm_type === ArrayRef || phi_wasm_type === AnyRef ||
                             phi_wasm_type === ExternRef
            is_wasm_struct_numeric = phi_julia_type in (Int128, UInt128)
            if is_phi_any_ref && !is_wasm_struct_numeric
                phi_ssa_val = Core.SSAValue(i)
                for use_stmt in code
                    # Check if used as GotoIfNot condition
                    if use_stmt isa Core.GotoIfNot && use_stmt.cond === phi_ssa_val
                        phi_wasm_type = I32
                        break
                    end
                    # Check if used as argument to boolean/comparison/arithmetic intrinsics
                    if use_stmt isa Expr && use_stmt.head === :call && length(use_stmt.args) >= 2
                        func = use_stmt.args[1]
                        if func isa GlobalRef && func.mod in (Core, Base, Core.Intrinsics)
                            fname = func.name
                            is_bool_op = fname in (:not_int, :and_int, :or_int, :xor_int)
                            is_cmp_op = fname in (:eq_int, :ne_int, :slt_int, :sle_int,
                                                   :ult_int, :ule_int)
                            # PURE-6021c: Arithmetic intrinsics that require numeric operands
                            is_arith_op = fname in (:add_int, :sub_int, :mul_int, :sdiv_int, :udiv_int,
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
                            if is_bool_op || is_cmp_op || is_arith_op
                                for arg in use_stmt.args[2:end]
                                    if arg === phi_ssa_val
                                        if is_arith_op || is_cmp_op
                                            # Arithmetic/comparison ops need I64 (Julia's default int width)
                                            inferred = julia_to_wasm_type_concrete(phi_julia_type, ctx)
                                            if inferred === I64
                                                phi_wasm_type = I64
                                            elseif inferred === I32
                                                phi_wasm_type = I32
                                            else
                                                phi_wasm_type = I64  # Default for Any/Union
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
            # PURE-6021c DEBUG: Trace externref phi allocations
            if get(ENV, "WASMTARGET_DEBUG_LOCALS", "") == "1"
                n_stmts = length(ctx.code_info.code)
                @warn "ALLOC PHI local $local_idx type=$(phi_wasm_type) for SSA $i (stmts=$n_stmts, n_params=$(ctx.n_params))" maxlog=200
            end
            # PURE-908: normalize AnyRef → ExternRef for phi locals
            push!(ctx.locals, phi_wasm_type === AnyRef ? ExternRef : phi_wasm_type)
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
function allocate_ssa_locals!(ctx::CompilationContext)
    code = ctx.code_info.code

    # Count uses of each SSA value
    ssa_uses = Dict{Int, Int}()
    for stmt in code
        count_ssa_uses!(stmt, ssa_uses)
    end

    # Find loop bounds (header to backward goto)
    loop_bounds = Dict{Int, Int}()  # header => back_edge_idx
    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode && stmt.label < i
            # This is a backward jump
            header = stmt.label
            loop_bounds[header] = i
        end
    end

    # First pass: allocate locals for SSAs used more than once or with intervening ops
    needs_local_set = Set{Int}()

    # Find SSAs defined inside a loop but used outside
    # These need locals because stack values don't persist across Wasm block boundaries
    for (header, back_edge) in loop_bounds
        for (i, stmt) in enumerate(code)
            # Check if SSA i is defined inside this loop
            if i >= header && i <= back_edge
                # Check if it's used after the loop (in return or other statements)
                for (j, other) in enumerate(code)
                    if j > back_edge && references_ssa(other, i)
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
    for (i, stmt) in enumerate(code)
        if stmt isa Core.PhiNode
            for j in 1:length(stmt.values)
                if isassigned(stmt.values, j)
                    val = stmt.values[j]
                    if val isa Core.SSAValue && 1 <= val.id <= length(code) && !(code[val.id] isa Core.PhiNode)
                        # This is a non-phi SSA referenced by a phi - needs local
                        push!(needs_local_set, val.id)
                    end
                end
            end
        end
    end

    # Find SSA values referenced by PiNodes that have control flow between definition and use
    # PiNodes narrow types after branch conditions, but the original value must be preserved
    for (i, stmt) in enumerate(code)
        if stmt isa Core.PiNode && stmt.val isa Core.SSAValue
            val_id = stmt.val.id
            # Check if there's control flow between the definition and this PiNode
            has_control_flow = false
            for j in (val_id + 1):(i - 1)
                if code[j] isa Core.GotoNode || code[j] isa Core.GotoIfNot
                    has_control_flow = true
                    break
                end
            end
            if has_control_flow
                push!(needs_local_set, val_id)
            end
        end
    end

    # Find SSAs that produce values and are followed by control flow
    # In Wasm, stack values don't persist across block boundaries
    # So any value produced before a GotoNode/GotoIfNot/PhiNode must be stored
    for (i, stmt) in enumerate(code)
        if produces_stack_value(stmt) && i < length(code)
            next_stmt = code[i + 1]
            # If the NEXT statement is control flow (not intermediate), this SSA needs a local
            # This handles cases where we create a value and immediately enter control flow
            if next_stmt isa Core.GotoNode || next_stmt isa Core.GotoIfNot
                push!(needs_local_set, i)
            end
        end
        # PiNodes used across control flow boundaries need locals.
        # Without a local, compile_value assumes the value is on the stack,
        # but in branching code the stack value may be in a different block.
        if stmt isa Core.PiNode && !haskey(ctx.phi_locals, i)
            # Check if there's any control flow between this PiNode and its uses
            for j in (i+1):length(code)
                use_stmt = code[j]
                if references_ssa(use_stmt, i) && !(use_stmt isa Core.PhiNode)
                    # Found a non-phi use. If there's control flow between PiNode and use, need a local.
                    has_cf_between = false
                    for k in (i+1):(j-1)
                        if code[k] isa Core.GotoNode || code[k] isa Core.GotoIfNot
                            has_cf_between = true
                            break
                        end
                    end
                    if has_cf_between
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
    for (i, stmt) in enumerate(code)
        if produces_stack_value(stmt)
            # Check all uses of this SSA
            found_use = false
            for (j, use_stmt) in enumerate(code)
                if j > i && references_ssa(use_stmt, i)
                    found_use = true
                    # Check if there's any control flow between definition and use
                    has_cf = false
                    for k in (i+1):(j-1)
                        if code[k] isa Core.GotoNode || code[k] isa Core.GotoIfNot
                            has_cf = true
                            break
                        end
                    end
                    if has_cf
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
        elseif use_count > 1 || needs_local(ctx, ssa_id)
            push!(needs_local_set, ssa_id)
        end
    end

    # Second pass: ALL SSA args in calls/invokes/new/return/GotoIfNot need locals.
    # In Wasm, we can't rely on stack values being available because the stackified
    # flow generator may insert block boundaries between the SSA definition and its use.
    for (i, stmt) in enumerate(code)
        if stmt isa Expr
            # All SSA values referenced in ANY expression need locals
            for arg in stmt.args
                if arg isa Core.SSAValue
                    push!(needs_local_set, arg.id)
                end
            end
        elseif stmt isa Core.ReturnNode && isdefined(stmt, :val) && stmt.val isa Core.SSAValue
            push!(needs_local_set, stmt.val.id)
        elseif stmt isa Core.GotoIfNot && stmt.cond isa Core.SSAValue
            push!(needs_local_set, stmt.cond.id)
        elseif stmt isa Core.PiNode && stmt.val isa Core.SSAValue
            push!(needs_local_set, stmt.val.id)
        end

        # Also handle :new expressions - struct fields need correct ordering
        if stmt isa Expr && stmt.head === :new
            # args[1] is the type, args[2:end] are field values
            field_values = stmt.args[2:end]
            ssa_args = [arg.id for arg in field_values if arg isa Core.SSAValue]

            # If there are multiple field values and any is an SSA, all SSA args need locals
            # This ensures we can push values in the correct field order
            if length(field_values) > 1 && !isempty(ssa_args)
                for id in ssa_args
                    push!(needs_local_set, id)
                end
            end
        end

        # Handle setfield! - the value arg needs a local if it's an SSA
        # because struct.set expects [ref, value] order, but if value is a single-use
        # SSA from a previous statement, it's already on the stack before we push ref
        if stmt isa Expr && stmt.head === :call
            func = stmt.args[1]
            is_setfield = (func isa GlobalRef &&
                          ((func.mod === Core && func.name === :setfield!) ||
                           (func.mod === Base && func.name === :setfield!)))
            if is_setfield && length(stmt.args) >= 4
                value_arg = stmt.args[4]  # args = [func, obj, field, value]
                if value_arg isa Core.SSAValue
                    push!(needs_local_set, value_arg.id)
                end
            end
        end

        # Handle :call expressions where a non-SSA arg appears BEFORE an SSA arg
        # This causes stack ordering issues: the SSA from the previous statement
        # is already on the stack, but we need to push the non-SSA first.
        # Example: slt_int(0, %1) - need to push 0, then %1, but %1 is already on stack
        # ONLY applies to numeric SSA values (struct refs have different handling)
        if stmt isa Expr && stmt.head === :call
            args = stmt.args[2:end]  # Skip function ref
            seen_non_ssa = false
            for arg in args
                if !(arg isa Core.SSAValue)
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
        end

        # Handle Core.tuple calls - same as :new, need locals for SSA args
        # when there are multiple elements to ensure correct struct.new field ordering
        if stmt isa Expr && stmt.head === :call
            func = stmt.args[1]
            is_tuple = func isa GlobalRef && func.mod === Core && func.name === :tuple
            if is_tuple
                args = stmt.args[2:end]
                ssa_args = [arg.id for arg in args if arg isa Core.SSAValue]
                # If there are multiple SSA args, all of them need locals to ensure
                # correct ordering (even if there are no non-SSA args)
                # Also need locals if there are non-SSA args mixed with SSA args
                has_non_ssa_args = any(!(arg isa Core.SSAValue) for arg in args)
                if (has_non_ssa_args && !isempty(ssa_args)) || length(ssa_args) > 1
                    for id in ssa_args
                        push!(needs_local_set, id)
                    end
                end
            end
        end

    end

    # Actually allocate the locals
    for ssa_id in sort(collect(needs_local_set))
        if !haskey(ctx.ssa_locals, ssa_id)  # Skip phi nodes already added
            ssa_type = get(ctx.ssa_types, ssa_id, Any)

            # Skip multi-arg memoryrefnew results - they leave [array_ref, i32_index] on stack
            # and can't be stored in a single local. They must be used immediately.
            stmt = ctx.code_info.code[ssa_id]
            if stmt isa Expr && stmt.head === :call
                func = stmt.args[1]
                is_memrefnew = (func isa GlobalRef &&
                                (func.mod === Core || func.mod === Base) &&
                                func.name === :memoryrefnew) ||
                               (func === :(Core.memoryrefnew)) ||
                               (func === :(Base.memoryrefnew))
                if is_memrefnew && length(stmt.args) >= 4  # func + 3 args = 4 total
                    # Multi-arg memoryrefnew - don't allocate a local
                    continue
                end
            end

            # PURE-913: compilerbarrier(:type, value)::Any — use inner value's type
            # Runtime intrinsics use @noinline + inferencebarrier, which inserts
            # compilerbarrier(:type, value)::Any. The SSA type is Any → ExternRef,
            # but the actual value is the inner arg's type (e.g., Int32 → I32).
            # If we allocate ExternRef, the safety check replaces the i32 with ref.null.
            # Also update ctx.ssa_types so compile_statement safety check uses the real type.
            if stmt isa Expr && stmt.head === :call
                func = stmt.args[1]
                is_compilerbarrier = (func isa GlobalRef &&
                    (func.mod === Core || func.mod === Base) &&
                    func.name === :compilerbarrier)
                if is_compilerbarrier && length(stmt.args) >= 3
                    inner_val = stmt.args[3]  # args = [func, kind, value]
                    inner_type = nothing
                    if inner_val isa Core.SSAValue
                        inner_type = get(ctx.ssa_types, inner_val.id, nothing)
                    elseif inner_val isa Core.Argument
                        arg_idx = inner_val.n
                        if arg_idx <= length(ctx.arg_types)
                            inner_type = ctx.arg_types[arg_idx]
                        end
                    else
                        # Literal value — infer type from the value itself
                        inner_type = typeof(inner_val)
                    end
                    if inner_type !== nothing && inner_type !== Any && inner_type !== Union{}
                        ssa_type = inner_type
                        ctx.ssa_types[ssa_id] = inner_type  # Update for safety check
                    end
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

            # For PiNodes: the local type must match what compile_value(stmt.val)
            # will actually push on the stack. If the source value has a local,
            # that local's type is what will be on the stack (via local.get).
            effective_type = ssa_type
            if stmt isa Core.PiNode
                narrowed_wasm = julia_to_wasm_type_concrete(ssa_type, ctx)
                # Check if the source value has a local with a different type
                src_wasm_type = nothing
                if stmt.val isa Core.SSAValue
                    if haskey(ctx.ssa_locals, stmt.val.id)
                        src_local_idx = ctx.ssa_locals[stmt.val.id]
                        src_array_idx = src_local_idx - ctx.n_params + 1
                        if src_array_idx >= 1 && src_array_idx <= length(ctx.locals)
                            src_wasm_type = ctx.locals[src_array_idx]
                        end
                    elseif haskey(ctx.phi_locals, stmt.val.id)
                        src_local_idx = ctx.phi_locals[stmt.val.id]
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
                    # Skip julia_to_wasm_type_concrete for effective_type — we'll set wasm_type directly below.
                elseif !(narrowed_wasm isa ConcreteRef) && narrowed_wasm !== StructRef && narrowed_wasm !== ArrayRef && narrowed_wasm !== AnyRef
                    # Numeric PiNode — use the value's type for the local since
                    # the Wasm representation is the same (i32/i64/f32/f64)
                    if stmt.val isa Core.SSAValue
                        val_type = get(ctx.ssa_types, stmt.val.id, nothing)
                        if val_type !== nothing
                            effective_type = val_type
                        end
                    elseif stmt.val isa Core.Argument
                        arg_idx = stmt.val.n
                        if arg_idx <= length(ctx.code_info.slottypes)
                            effective_type = ctx.code_info.slottypes[arg_idx]
                        end
                    end
                end
            end

            wasm_type = julia_to_wasm_type_concrete(effective_type, ctx)

            # For PiNodes where source local has a different NUMERIC type,
            # use the source's actual Wasm type to avoid local.get → local.set mismatches.
            # For ref types, DON'T widen — the compile_statement safety check handles
            # the store mismatch by emitting ref.null of the target type. Widening ref
            # types breaks downstream struct.get/array.get operations.
            if stmt isa Core.PiNode && stmt.val isa Core.SSAValue
                src_local_wasm = nothing
                if haskey(ctx.ssa_locals, stmt.val.id)
                    src_li = ctx.ssa_locals[stmt.val.id]
                    src_ai = src_li - ctx.n_params + 1
                    if src_ai >= 1 && src_ai <= length(ctx.locals)
                        src_local_wasm = ctx.locals[src_ai]
                    end
                elseif haskey(ctx.phi_locals, stmt.val.id)
                    src_li = ctx.phi_locals[stmt.val.id]
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
                    # PURE-324: Also allow widening when source is numeric but target is
                    # ConcreteRef from an all-numeric Union (e.g., Union{Int64, UInt32}).
                    # The phi was widened to I64, but the PiNode SSA got ConcreteRef from
                    # julia_to_wasm_type_concrete. Use the source's numeric type.
                    is_numeric_union_tgt = wasm_type isa ConcreteRef && effective_type isa Union &&
                        let ut = Base.uniontypes(effective_type),
                            nn = filter(t -> t !== Nothing, ut)
                            !isempty(nn) && all(t -> let wt = julia_to_wasm_type(t); wt === I32 || wt === I64 || wt === F32 || wt === F64 end, nn)
                        end
                    # PURE-324: Don't widen I32 → I64 for PiNodes. The PiNode's
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
            if stmt isa Expr && stmt.head === :call && length(stmt.args) >= 3
                sfunc = stmt.args[1]
                # PURE-049: Match any module for getfield/getproperty
                is_gf = (sfunc isa GlobalRef &&
                         sfunc.name in (:getfield, :getproperty))
                if is_gf
                    obj_arg = stmt.args[2]
                    field_ref = stmt.args[3]
                    obj_type = infer_value_type(obj_arg, ctx)
                    if obj_type isa DataType && isstructtype(obj_type) && !isprimitivetype(obj_type)
                        field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
                        if field_sym isa Symbol && hasfield(obj_type, field_sym)
                            jft = fieldtype(obj_type, field_sym)
                            if jft === Any
                                wasm_type = ExternRef
                            end
                        end
                    end
                end
                # Also check memoryrefget on Any-element arrays
                if sfunc isa GlobalRef && sfunc.name === :memoryrefget
                    ref_arg = stmt.args[2]
                    ref_type = infer_value_type(ref_arg, ctx)
                    if ref_type isa DataType
                        elt = nothing
                        if ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1
                            elt = ref_type.parameters[1]
                        elseif ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2
                            elt = ref_type.parameters[2]
                        end
                        if elt === Any
                            wasm_type = ExternRef
                        end
                    end
                end
            end

            # Fix PURE-036be/PURE-046: When wasm_type is ExternRef but SSA is used in numeric context,
            # type the local based on the Julia type inference to match the expected operand type.
            # This handles dead code after UNREACHABLE and Any-typed struct fields used in comparisons.
            if wasm_type === ExternRef
                ssa_val = Core.SSAValue(ssa_id)
                for (j, use_stmt) in enumerate(code)
                    # Check if used as GotoIfNot condition
                    if use_stmt isa Core.GotoIfNot && use_stmt.cond === ssa_val
                        wasm_type = I32
                        break
                    end
                    # Check if used as argument to comparison/boolean intrinsics
                    if use_stmt isa Expr && use_stmt.head === :call && length(use_stmt.args) >= 2
                        func = use_stmt.args[1]
                        if func isa GlobalRef && func.mod in (Core, Base, Core.Intrinsics)
                            fname = func.name
                            # Boolean ops that take boolean/i32 operands
                            is_bool_op = fname in (:not_int, :and_int, :or_int, :xor_int)
                            # Comparison ops that can take i32 or i64 operands
                            is_cmp_op = fname in (:eq_int, :ne_int, :slt_int, :sle_int,
                                                  :ult_int, :ule_int)
                            # PURE-6021c: Arithmetic and other numeric intrinsics that require
                            # numeric operands — fixes externref/i64 mismatch in builtin_effects
                            is_arith_op = fname in (:add_int, :sub_int, :mul_int, :sdiv_int, :udiv_int,
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
                            if is_bool_op || is_cmp_op || is_arith_op
                                for arg in use_stmt.args[2:end]
                                    if arg === ssa_val
                                        # PURE-046: Use Julia type to determine correct Wasm operand type
                                        # Compute what Wasm type the Julia type would normally map to
                                        inferred_wasm = julia_to_wasm_type_concrete(effective_type, ctx)
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
            # PURE-6021c DEBUG: Trace externref allocations for diagnostics
            if get(ENV, "WASMTARGET_DEBUG_LOCALS", "") == "1"
                n_stmts = length(ctx.code_info.code)
                @warn "ALLOC SSA local $local_idx type=$(wasm_type) for SSA $ssa_id (stmts=$n_stmts, n_params=$(ctx.n_params))" maxlog=200
            end
            # PURE-908: normalize AnyRef → ExternRef for SSA locals
            push!(ctx.locals, wasm_type === AnyRef ? ExternRef : wasm_type)
            ctx.ssa_locals[ssa_id] = local_idx
        end
    end

end

"""
PURE-6024: Allocate WASM locals for slot variables in unoptimized IR (may_optimize=false).

In unoptimized IR, local variables are represented as SlotNumber assignments:
  code[i] = Expr(:(=), SlotNumber(n), rhs_expr)
  code[j] = SlotNumber(n)  # reads the assigned value

Slots 1..n_params+1 are the function self + arguments (mapped to WASM params).
Slots > n_params+1 are local variables that need dedicated WASM locals.

This function scans for slot assignments, determines their types from ssavaluetypes,
and allocates WASM locals. The slot_locals dict maps SlotNumber.id → WASM local index.
"""
function allocate_slot_locals!(ctx::CompilationContext)
    code = ctx.code_info.code
    n_arg_slots = length(ctx.arg_types) + 1  # slot 1 = self, slot 2..n+1 = args

    for (i, stmt) in enumerate(code)
        if stmt isa Expr && stmt.head === :(=) && length(stmt.args) >= 2
            lhs = stmt.args[1]
            if lhs isa Core.SlotNumber && lhs.id > n_arg_slots
                slot_id = lhs.id
                if !haskey(ctx.slot_locals, slot_id)
                    # Determine type from ssavaluetypes for this statement
                    ssa_type = get(ctx.ssa_types, i, Any)
                    wasm_type = julia_to_wasm_type_concrete(ssa_type, ctx)
                    # Normalize AnyRef → ExternRef
                    if wasm_type === AnyRef
                        wasm_type = ExternRef
                    end
                    local_idx = ctx.n_params + length(ctx.locals)
                    push!(ctx.locals, wasm_type)
                    ctx.slot_locals[slot_id] = local_idx
                end
            end
        end
    end
end

"""
Check if an SSA value needs a local (e.g., not used immediately or used after other stack-producing operations).
"""
function needs_local(ctx::CompilationContext, ssa_id::Int)
    code = ctx.code_info.code

    # Find where this SSA is used
    use_idx = nothing
    for (i, stmt) in enumerate(code)
        if i != ssa_id && references_ssa(stmt, ssa_id)
            use_idx = i
            break
        end
    end

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
        use_stmt = code[actual_use_idx]
        # Check if this is a single-arg memoryrefnew passthrough
        if use_stmt isa Expr && use_stmt.head === :call
            func = use_stmt.args[1]
            is_memrefnew = (func isa GlobalRef &&
                            (func.mod === Core || func.mod === Base) &&
                            (func.name === :memoryrefnew || func.name === :memoryref))
            if is_memrefnew && length(use_stmt.args) == 2  # func + 1 arg = single-arg passthrough
                # Find where this passthrough result is used
                next_use = nothing
                for (j, s) in enumerate(code)
                    if j != actual_use_idx && references_ssa(s, actual_use_idx)
                        next_use = j
                        break
                    end
                end
                if next_use !== nothing
                    actual_use_idx = next_use
                    continue
                end
            end
        end
        break
    end

    # If there are any statements between definition and use that produce values,
    # we need a local because those values will mess up the stack
    for i in (ssa_id + 1):(actual_use_idx - 1)
        stmt = code[i]
        if produces_stack_value(stmt)
            return true
        end
    end

    # Also need local if there's control flow between definition and use
    for i in (ssa_id + 1):(actual_use_idx - 1)
        stmt = code[i]
        if stmt isa Core.GotoIfNot || stmt isa Core.GotoNode
            return true
        end
    end

    # If SSA is defined inside a loop and there are conditionals in the loop,
    # we need a local to ensure stack balance across control flow
    for header in ctx.loop_headers
        # Find corresponding back-edge
        back_edge = nothing
        for (i, stmt) in enumerate(code)
            if stmt isa Core.GotoNode && stmt.label == header
                back_edge = i
                break
            end
        end
        if back_edge !== nothing && ssa_id >= header && ssa_id <= back_edge
            # SSA is defined inside this loop
            # Check if there are any conditionals in the loop
            for i in header:back_edge
                if code[i] isa Core.GotoIfNot
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
Check if a statement produces a value on the stack.
"""
function produces_stack_value(stmt)
    # Most expressions produce values
    if stmt isa Expr
        return stmt.head in (:call, :invoke, :new, :boundscheck, :tuple)
    end
    if stmt isa Core.PhiNode
        return true
    end
    if stmt isa Core.PiNode
        return true
    end
    # Literals and SSA refs also produce values (but shouldn't appear as statements)
    if stmt isa Number || stmt isa Core.SSAValue
        return true
    end
    return false
end

"""
Check if a statement is a passthrough that doesn't emit bytecode but relies on
a value already being on the stack from an earlier SSA.
Examples:
- memoryrefnew(memory) - just passes through the array reference
- Core.memoryref(memory) via :invoke - also a passthrough
Note: Vector{T} is NO LONGER a passthrough - it's now a struct with (ref, size) fields.
"""
function is_passthrough_statement(stmt, ctx::CompilationContext)
    if !(stmt isa Expr)
        return false
    end

    # Check for memoryrefnew with single arg (passthrough pattern) via :call
    if stmt.head === :call
        func = stmt.args[1]
        is_memrefnew = (func isa GlobalRef && func.mod === Core && func.name === :memoryrefnew) ||
                       (func === :(Core.memoryrefnew))
        if is_memrefnew && length(stmt.args) == 2
            # Single arg memoryrefnew is a passthrough
            return true
        end
    end

    # Check for Core.memoryref via :invoke - this is also a passthrough
    # Julia uses :invoke for Core.memoryref(memory::Memory{T}) -> MemoryRef{T}
    # In WasmGC, this is a no-op since Memory and MemoryRef are both the array
    if stmt.head === :invoke && length(stmt.args) >= 3
        # args[1] is MethodInstance, args[2] is function ref, args[3:end] are actual args
        func_ref = stmt.args[2]
        args = stmt.args[3:end]

        # Check if it's Core.memoryref with single arg
        is_memoryref = func_ref === :(Core.memoryref) ||
                       (func_ref isa GlobalRef && func_ref.mod === Core && func_ref.name === :memoryref)

        if is_memoryref && length(args) == 1
            arg = args[1]
            # It's a passthrough if the single arg is an SSA that doesn't have a local
            # (meaning its value is still on the stack from the previous statement)
            if arg isa Core.SSAValue && !haskey(ctx.ssa_locals, arg.id)
                return true
            end
        end
    end

    # Note: Vector %new is NO LONGER a passthrough
    # Vector{T} is now a struct with (ref, size) fields for setfield! support

    return false
end

"""
Count SSA uses in a statement.
"""
function count_ssa_uses!(stmt, uses::Dict{Int, Int})
    if stmt isa Core.SSAValue
        uses[stmt.id] = get(uses, stmt.id, 0) + 1
    elseif stmt isa Expr
        for arg in stmt.args
            count_ssa_uses!(arg, uses)
        end
    elseif stmt isa Core.ReturnNode && isdefined(stmt, :val)
        count_ssa_uses!(stmt.val, uses)
    elseif stmt isa Core.GotoIfNot
        count_ssa_uses!(stmt.cond, uses)
    elseif stmt isa Core.PhiNode
        for i in 1:length(stmt.values)
            if isassigned(stmt.values, i)
                count_ssa_uses!(stmt.values[i], uses)
            end
        end
    elseif stmt isa Core.PiNode
        # PURE-324: PiNode references a source value — count it so phi nodes
        # that are only referenced by PiNodes get their ssa_locals mapping
        count_ssa_uses!(stmt.val, uses)
    end
end

"""
Check if a statement references an SSA value.
"""
function references_ssa(stmt, ssa_id::Int)::Bool
    if stmt isa Core.SSAValue
        return stmt.id == ssa_id
    elseif stmt isa Expr
        return any(references_ssa(arg, ssa_id) for arg in stmt.args)
    elseif stmt isa Core.ReturnNode && isdefined(stmt, :val)
        return references_ssa(stmt.val, ssa_id)
    elseif stmt isa Core.GotoIfNot
        return references_ssa(stmt.cond, ssa_id)
    end
    return false
end

"""
Get the Julia type of an SSA value or other value reference.
Used for type checking (e.g., in isa() calls).
"""
function get_ssa_type(ctx::CompilationContext, val)::Type
    if val isa Core.SSAValue
        return get(ctx.ssa_types, val.id, Any)
    elseif val isa Core.Argument
        # Handle argument references
        if ctx.is_compiled_closure
            idx = val.n
        else
            idx = val.n - 1
        end
        if idx >= 1 && idx <= length(ctx.arg_types)
            return ctx.arg_types[idx]
        end
        return Any
    elseif val isa Type
        return Type{val}  # It's a type constant
    else
        return typeof(val)
    end
end

"""
Analyze the IR to determine types of SSA values.
Uses CodeInfo.ssavaluetypes for accurate type information.
"""
function analyze_ssa_types!(ctx::CompilationContext)
    # Use Julia's type inference results when available
    ssatypes = ctx.code_info.ssavaluetypes
    if ssatypes isa Vector
        for (i, T) in enumerate(ssatypes)
            # Store all concrete types including Nothing (needed for function dispatch)
            # Only skip Any as it provides no useful information
            if T !== Any
                # PURE-6024: Widen inference lattice elements to concrete Julia types.
                # Unoptimized IR (may_optimize=false) retains Core.Const, Core.PartialStruct,
                # etc. in ssavaluetypes. Downstream code (julia_to_wasm_type_concrete,
                # allocate_ssa_locals!) expects plain Julia types, not lattice elements.
                actual_T = T isa Type ? T : Core.Compiler.widenconst(T)
                ctx.ssa_types[i] = actual_T
            end
        end
    end

    # Override: if an SSA is a getfield/getproperty on a struct field typed as Any,
    # or a memoryrefget on an array with Any elements, force the SSA type to Any.
    # This ensures the local is allocated as externref (matching what struct.get/array.get
    # actually produces), preventing type mismatches with local.set.
    for (i, stmt) in enumerate(ctx.code_info.code)
        if stmt isa Expr && stmt.head === :call && length(stmt.args) >= 3
            func = stmt.args[1]
            # Check getfield/getproperty on Any-typed struct field
            # PURE-049: Match any module — getproperty/getfield may appear as
            # Compiler.getproperty, Base.getfield, etc. depending on the caller's module
            is_gf = (func isa GlobalRef &&
                     func.name in (:getfield, :getproperty))
            if is_gf
                obj_arg = stmt.args[2]
                field_ref = stmt.args[3]
                obj_type = infer_value_type(obj_arg, ctx)
                # Check the Julia field type directly (no registry lookup needed)
                # PURE-325: Also allow non-concrete Tuple types (e.g., Tuple{Any, Int64})
                # isconcretetype(Tuple{Any, Int64}) = false because Any is abstract, but
                # fieldtype/fieldcount still work correctly on Tuple DataTypes.
                is_concrete_enough = isconcretetype(obj_type) || (obj_type <: Tuple && obj_type isa DataType)
                if obj_type isa DataType && isstructtype(obj_type) && !isprimitivetype(obj_type) && is_concrete_enough
                    field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
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
            if func isa GlobalRef && func.name === :memoryrefget
                ref_arg = stmt.args[2]
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

    # Fallback: infer from calls for any missing types
    for (i, stmt) in enumerate(ctx.code_info.code)
        if !haskey(ctx.ssa_types, i)
            if stmt isa Expr && stmt.head === :call
                # PURE-325: Skip memoryrefset! — its return type is the stored element (Any),
                # NOT the MemoryRef first argument. infer_call_type would incorrectly infer
                # MemoryRef{T}, causing the SSA local to be allocated as ConcreteRef (array type)
                # instead of ExternRef. This leads to illegal ref.cast at runtime.
                _func_arg = stmt.args[1]
                if _func_arg isa GlobalRef && _func_arg.name === :memoryrefset!
                    continue
                end
                ctx.ssa_types[i] = infer_call_type(stmt, ctx)
            elseif stmt isa Expr && stmt.head === :invoke
                # For invoke expressions with Any type, get the actual method return type
                mi_or_ci = stmt.args[1]
                mi = if mi_or_ci isa Core.MethodInstance
                    mi_or_ci
                elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
                    mi_or_ci.def
                else
                    nothing
                end
                if mi isa Core.MethodInstance
                    meth = mi.def
                    if meth isa Method
                        # Get the function reference from the invoke expression
                        func_ref = stmt.args[2]
                        if func_ref isa GlobalRef
                            func = try getfield(func_ref.mod, func_ref.name) catch; nothing end
                            if func !== nothing && ctx.func_registry !== nothing && haskey(ctx.func_registry.by_ref, func)
                                # Look up in registry by function reference
                                infos = ctx.func_registry.by_ref[func]
                                if !isempty(infos)
                                    # Use the first matching function's return type
                                    ctx.ssa_types[i] = infos[1].return_type
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function infer_call_type(expr::Expr, ctx::CompilationContext)
    func = expr.args[1]
    args = expr.args[2:end]

    # Comparison operations return Bool
    if is_comparison(func)
        return Bool
    end

    # PURE-325: getfield returns the field type, not the object type
    if func isa GlobalRef && func.name in (:getfield, :getproperty) && length(args) >= 2
        obj_type = infer_value_type(args[1], ctx)
        field_ref = args[2]
        if obj_type isa DataType && isstructtype(obj_type) && !isabstracttype(obj_type)
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            try
                if field_sym isa Symbol && hasfield(obj_type, field_sym)
                    return fieldtype(obj_type, field_sym)
                elseif field_sym isa Integer && 1 <= field_sym <= fieldcount(obj_type)
                    return fieldtype(obj_type, Int(field_sym))
                end
            catch
                # fieldcount may fail for types without definite field count
            end
        end
    end

    # PURE-325: Infer return type from first argument for most intrinsics.
    # For calls where the first arg is Type{T} (constructor/conversion), return Any
    # since the return type is T, not Type{T}. Same for known non-identity functions.
    if length(args) > 0
        arg1_type = infer_value_type(args[1], ctx)
        # Type{T} as first arg means this is a constructor — return type is T, not Type{T}
        if arg1_type isa DataType && arg1_type <: Type
            return Any  # Safe default for constructors
        end
        # Known functions where return type != first arg type
        if func isa GlobalRef && func.name in (:push!, :pushfirst!, :pop!, :popfirst!,
                                                 :setindex!, :insert!, :deleteat!,
                                                 :write, :print, :println, :show,
                                                 :compilerbarrier)
            return Any
        end
        return arg1_type
    end

    return Any  # Safe default — maps to ExternRef
end

function infer_value_type(val, ctx::CompilationContext)
    if val isa Core.Argument
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
            # PURE-324: Core.Argument(1) in a non-closure is the function reference itself.
            # This occurs in kwarg wrapper methods that pass `self` to the inner #method#N.
            # Return typeof(func_ref) so cross-function lookup can match the registered signature.
            return typeof(ctx.func_ref)
        end
    elseif val isa Core.SlotNumber
        # PURE-6024: SlotNumber is the unoptimized IR equivalent of Core.Argument.
        # Slot 1 = function self, slot 2+ = arguments (same indexing as Argument).
        # For local variable slots (not params), use slottypes from CodeInfo.
        if ctx.is_compiled_closure
            idx = val.id
        else
            idx = val.id - 1
        end
        if idx >= 1 && idx <= length(ctx.arg_types)
            return ctx.arg_types[idx]
        elseif val.id >= 1 && val.id <= length(ctx.code_info.slottypes)
            # Local variable slot — return its inferred type from CodeInfo
            return ctx.code_info.slottypes[val.id]
        end
    elseif val isa Core.SSAValue
        return get(ctx.ssa_types, val.id, Any)
    elseif val isa Int64 || val isa Int
        return Int64
    elseif val isa Int32
        return Int32
    elseif val isa Float64
        return Float64
    elseif val isa Float32
        return Float32
    elseif val isa Bool
        return Bool
    elseif val isa Char
        return Char
    elseif val isa WasmGlobal
        return typeof(val)
    elseif val isa GlobalRef
        # GlobalRef to a constant - infer type from the actual value
        try
            actual_val = getfield(val.mod, val.name)
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
                # PURE-4155: Return Type{actual_val} (e.g., Type{Int64}) instead of bare Type.
                # This allows get_concrete_wasm_type to return ConcreteRef for the DataType struct,
                # which triggers extern_convert_any bridging when passed to externref-typed params.
                return Type{actual_val}
            else
                return typeof(actual_val)
            end
        catch
            # If we can't evaluate, default to Int64
        end
    elseif val isa QuoteNode
        # QuoteNode wraps a value - return the type of the wrapped value
        return typeof(val.value)
    elseif val isa Type
        # Type{T} references - return Type{T}
        return Type{val}
    elseif val isa Function
        # PURE-324: Function values passed as arguments (e.g., kwarg wrappers pass `self` to inner method)
        # Return typeof(f) so cross-function lookup can match the registered signature
        return typeof(val)
    elseif isprimitivetype(typeof(val))
        # Custom primitive type (e.g., JuliaSyntax.Kind) - return actual type
        return typeof(val)
    elseif isstructtype(typeof(val)) && !isa(val, Type) && !isa(val, Function) && !isa(val, Module)
        # Struct constant - return actual type
        return typeof(val)
    end
    return Int64
end

"""
    emit_ref_cast_if_structref(bytes, val, target_type_idx, ctx) -> bytes

Check if `val` will produce `structref` on the Wasm stack (due to union-typed local),
and if so, append `ref.cast null \$target_type_idx` to narrow it for struct_get.
"""
function emit_ref_cast_if_structref!(bytes::Vector{UInt8}, val, target_type_idx::Integer, ctx::CompilationContext)
    local_wasm_type = nothing
    if val isa Core.SSAValue
        local_idx = get(ctx.ssa_locals, val.id, nothing)
        if local_idx === nothing
            local_idx = get(ctx.phi_locals, val.id, nothing)
        end
        if local_idx !== nothing
            arr_idx = local_idx - ctx.n_params + 1
            if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                local_wasm_type = ctx.locals[arr_idx]
            end
        end
    end
    if local_wasm_type === StructRef || local_wasm_type === AnyRef
        # Value on stack is structref/anyref, but struct_get/array_get needs (ref null $target_type_idx)
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.REF_CAST_NULL)
        append!(bytes, encode_leb128_signed(Int64(target_type_idx)))
    elseif local_wasm_type === ExternRef
        # PURE-6025: Value on stack is externref (from Any-typed local or Dict/Vector retrieval).
        # Must convert externref → anyref → (ref null $target_type_idx) for struct_get.
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ANY_CONVERT_EXTERN)
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.REF_CAST_NULL)
        append!(bytes, encode_leb128_signed(Int64(target_type_idx)))
    end
    return bytes
end

"""
    _get_local_wasm_type(val, compiled_bytes, ctx) -> WasmValType or nothing

PURE-6025: Get the Wasm type of the value that `compiled_bytes` pushes onto the stack.
Checks SSA locals, phi locals, and parameter types. Returns the local's Wasm type
or nothing if it can't be determined.
"""
function _get_local_wasm_type(val, compiled_bytes::Vector{UInt8}, ctx::CompilationContext)
    # Check via val (SSA or Argument)
    if val isa Core.SSAValue
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
    end
    # Fallback: decode local_get from compiled bytes
    if length(compiled_bytes) >= 2 && compiled_bytes[1] == Opcode.LOCAL_GET
        src_idx = 0
        shift = 0
        pos = 2
        while pos <= length(compiled_bytes)
            b = compiled_bytes[pos]
            src_idx |= (Int(b & 0x7f) << shift)
            shift += 7
            pos += 1
            (b & 0x80) == 0 && break
        end
        if pos - 1 == length(compiled_bytes)
            if src_idx >= ctx.n_params
                arr_idx = src_idx - ctx.n_params + 1
                if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                    return ctx.locals[arr_idx]
                end
            else
                # Parameter — infer wasm type from arg_types
                # Wasm param N → arg_types[N+1] for non-closures (param 0 = arg_types[1])
                # Wasm param N → arg_types[N+1] for closures (param 0 = closure = arg_types[1])
                arg_idx = src_idx + 1
                if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
                    return get_concrete_wasm_type(ctx.arg_types[arg_idx], ctx.mod, ctx.type_registry)
                end
            end
        end
    end
    return nothing
end

"""
    _narrow_generic_local!(bytes, local_idx, ssa_id, ctx)

PURE-901: When a local has generic type (anyref/structref) but the SSA's Julia type
maps to a concrete Wasm type, emit `ref.cast null \$concrete_type` to narrow the value
on the stack. This ensures downstream struct_get/array_get see the correct type.

This is safe because ref.cast null on the correct type is a no-op at runtime,
and on the wrong type it traps (which indicates a real codegen bug).
"""
function _narrow_generic_local!(bytes::Vector{UInt8}, local_idx::Integer, ssa_id::Integer, ctx::CompilationContext)
    arr_idx = local_idx - ctx.n_params + 1
    if arr_idx < 1 || arr_idx > length(ctx.locals)
        return
    end
    local_wasm_type = ctx.locals[arr_idx]
    if !(local_wasm_type === AnyRef || local_wasm_type === StructRef || local_wasm_type === ExternRef)
        return  # Local is already concrete — no narrowing needed
    end
    # Look up the SSA's Julia type to find a concrete Wasm type
    ssa_julia_type = get(ctx.ssa_types, ssa_id, Any)
    if ssa_julia_type === Any || ssa_julia_type === Union{}
        return  # Can't narrow — don't know the concrete type
    end
    concrete_wasm = get_concrete_wasm_type(ssa_julia_type, ctx.mod, ctx.type_registry)
    if concrete_wasm isa ConcreteRef
        if local_wasm_type === ExternRef
            # PURE-6025: ExternRef needs any_convert_extern before ref.cast
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ANY_CONVERT_EXTERN)
        end
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.REF_CAST_NULL)
        append!(bytes, encode_leb128_signed(Int64(concrete_wasm.type_idx)))
    end
end

"""
Extract the global index from a WasmGlobal type.
The index is stored as a type parameter, so we extract it from the type.
"""
function get_wasm_global_idx(val, ctx::CompilationContext)::Union{Int, Nothing}
    val_type = infer_value_type(val, ctx)
    if val_type <: WasmGlobal
        # Extract IDX from WasmGlobal{T, IDX}
        return global_index(val_type)
    end
    return nothing
end

"""
Check if a call/invoke statement produces a value on the WASM stack.
Returns false for calls to functions that return Nothing (void).
This checks the function registry first (most reliable), then MethodInstance return type.
"""
function statement_produces_wasm_value(stmt::Expr, idx::Int, ctx::CompilationContext)::Bool
    # PURE-6024: memoryrefset! compiles to array.set (void in WASM).
    # The handler manages its own return value emission when an SSA local exists,
    # so this function must return false to prevent spurious DROP on empty stack.
    if stmt.head === :call && length(stmt.args) >= 1
        _f = stmt.args[1]
        if _f isa GlobalRef && _f.name === :memoryrefset!
            return false
        end
    end

    # Get the SSA type first
    stmt_type = get(ctx.ssa_types, idx, Any)

    # If SSA type is definitely Nothing, no value produced
    if stmt_type === Nothing
        return false
    end

    # If SSA type is Union{} (bottom type), the statement never returns so no value
    if stmt_type === Union{}
        return false
    end

    # NOTE: Union{T, Nothing} DOES produce a value (a union struct in WASM)
    # Only exact Nothing type means void return

    # Check the function registry first - this is the most reliable source
    # because it reflects what we actually compiled the function with
    if ctx.func_registry !== nothing
        # Extract the called function from the statement
        called_func = nothing
        call_arg_types = nothing

        if stmt.head === :invoke && length(stmt.args) >= 2
            # For invoke, args[2] is typically a GlobalRef to the function
            func_ref = stmt.args[2]
            if func_ref isa GlobalRef
                try
                    called_func = getfield(func_ref.mod, func_ref.name)
                    # Skip built-in functions that aren't in the registry
                    if called_func !== Base.getfield && called_func !== Core.getfield &&
                       called_func !== Base.setfield! && called_func !== Core.setfield!
                        # Get argument types from the remaining args
                        call_arg_types = Tuple{[infer_value_type(arg, ctx) for arg in stmt.args[3:end]]...}
                    end
                catch
                end
            end
        elseif stmt.head === :call && length(stmt.args) >= 1
            func_ref = stmt.args[1]
            if func_ref isa GlobalRef
                try
                    called_func = getfield(func_ref.mod, func_ref.name)
                    # Skip built-in functions that aren't in the registry
                    if called_func !== Base.getfield && called_func !== Core.getfield &&
                       called_func !== Base.setfield! && called_func !== Core.setfield!
                        call_arg_types = Tuple{[infer_value_type(arg, ctx) for arg in stmt.args[2:end]]...}
                    end
                catch
                end
            end
        end

        if called_func !== nothing && call_arg_types !== nothing
            # Only look up if the function is in our registry
            if haskey(ctx.func_registry.by_ref, called_func)
                try
                    target_info = get_function(ctx.func_registry, called_func, call_arg_types)
                    if target_info !== nothing
                        # Use the return type we actually compiled with
                        if target_info.return_type === Nothing
                            return false
                        else
                            return true
                        end
                    end
                catch
                    # If lookup fails (e.g., type mismatch), fall through to other checks
                end
            end
        end
    end

    # For invoke statements, check the MethodInstance's return type
    if stmt.head === :invoke && length(stmt.args) >= 1
        mi_or_ci = stmt.args[1]
        mi = if mi_or_ci isa Core.MethodInstance
            mi_or_ci
        elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
            mi_or_ci.def
        else
            nothing
        end
        if mi isa Core.MethodInstance
            # Get the return type from the MethodInstance
            # specTypes contains the return type
            ret_type = mi.specTypes
            # The return type is the rettype field when available
            if isdefined(mi, :rettype)
                ret_type = mi.rettype
                if ret_type === Nothing
                    return false
                end
            end
        end
    end

    # If SSA type is Any, be conservative and assume it might be Nothing
    # (e.g., when Julia's optimizer didn't infer the type precisely)
    if stmt_type === Any
        # Check if it's an invoke - we can get more precise info
        if stmt.head === :invoke && length(stmt.args) >= 1
            mi_or_ci = stmt.args[1]
            mi = if mi_or_ci isa Core.MethodInstance
                mi_or_ci
            elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
                mi_or_ci.def
            else
                nothing
            end
            if mi isa Core.MethodInstance && isdefined(mi, :rettype) && mi.rettype === Nothing
                return false
            end
            # If the function is a cross-module call (in our func_registry),
            # it produces a value because we compiled it with a non-void return type
            if mi isa Core.MethodInstance && ctx.func_registry !== nothing
                func_ref = length(stmt.args) >= 2 ? stmt.args[2] : nothing
                if func_ref isa GlobalRef
                    called_func = try
                        getfield(func_ref.mod, func_ref.name)
                    catch
                        nothing
                    end
                    if called_func !== nothing && haskey(ctx.func_registry.by_ref, called_func)
                        return true  # Function is compiled in this module, produces a value
                    end
                end
            end
        end
        # PURE-905: Also check :call statements against func_registry.
        # Cross-call handler emits CALL to functions that return values,
        # but the Julia SSA type may be Any. Check if the target function
        # in the registry has a non-Nothing return type.
        if stmt.head === :call && length(stmt.args) >= 1 && ctx.func_registry !== nothing
            func_ref = stmt.args[1]
            if func_ref isa GlobalRef
                called_func = try
                    getfield(func_ref.mod, func_ref.name)
                catch
                    nothing
                end
                if called_func !== nothing && haskey(ctx.func_registry.by_ref, called_func)
                    # Look up the specific method to check return type
                    call_arg_types = tuple([infer_value_type(arg, ctx) for arg in stmt.args[2:end]]...)
                    target_info = get_function(ctx.func_registry, called_func, call_arg_types)
                    if target_info === nothing && typeof(called_func) <: Function && isconcretetype(typeof(called_func))
                        target_info = get_function(ctx.func_registry, called_func, (typeof(called_func), call_arg_types...))
                    end
                    if target_info !== nothing && target_info.return_type !== Nothing
                        return true
                    end
                end
            end
        end
        # For Any type that's not a known Nothing invoke/call, assume no value produced
        return false
    end

    # For other types (concrete types that aren't Nothing), value is produced
    return true
end

