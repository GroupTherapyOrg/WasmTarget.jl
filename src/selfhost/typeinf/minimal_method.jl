# minimal_method.jl — Minimal WasmGC-friendly representations of Method/MethodMatch
#
# Core.Method is a C struct with 20+ fields. TypeInf only reads a subset.
# MinimalMethod pre-extracts those fields at build time for WasmGC emission.
#
# Core.MethodMatch similarly has 4 fields. MinimalMethodMatch captures them.
#
# Phase 2A-004: Design + extraction + emission of minimal representations.
#
# Usage:
#   methods = extract_all_methods(table::DictMethodTable, registry::TypeIDRegistry)
#   # methods is a MethodExtraction with:
#   #   .methods::Vector{MinimalMethod}  (all unique methods, indexed by method_idx)
#   #   .matches::Dict{Int32, Vector{MinimalMethodMatch}}  (type_id → matches)

using ..WasmTarget: WasmModule, add_struct_type!, add_global_ref!, add_array_type!,
                    I32, I64, ConcreteRef, Opcode, encode_leb128_unsigned, encode_leb128_signed,
                    FieldType

# ─── MinimalMethod ────────────────────────────────────────────────────────────
# Pre-extracted subset of Core.Method fields that typeinf reads.

struct MinimalMethod
    sig_type_id::Int32      # TypeID of the method signature (Tuple type)
    nargs::Int32            # Number of arguments (method.nargs)
    isva::Int32             # 1 if varargs, 0 otherwise (method.isva)
    has_generator::Int32    # 1 if @generated, 0 otherwise
    primary_world::Int64    # World when method was defined (reinterpret of UInt64)
    # World age validity is tracked at MethodLookupResult level via .valid_worlds
end

# ─── MinimalMethodMatch ───────────────────────────────────────────────────────
# Pre-extracted subset of Core.MethodMatch fields.

struct MinimalMethodMatch
    method_idx::Int32           # Index into MethodExtraction.methods (0-based)
    fully_covers::Int32         # 1 if fully covers call signature, 0 otherwise
    spec_types_type_id::Int32   # TypeID of specialized argument types (match.spec_types)
end

# ─── MethodExtraction ─────────────────────────────────────────────────────────
# Complete extraction of method data from a DictMethodTable.

struct MethodExtraction
    methods::Vector{MinimalMethod}              # Unique methods, indexed by method_idx
    method_to_idx::Dict{UInt, Int32}            # objectid(Method) → method_idx (0-based)
    matches::Dict{Int32, Vector{MinimalMethodMatch}}  # TypeID → Vector{MinimalMethodMatch}
end

# ─── Extraction Functions ─────────────────────────────────────────────────────

"""
    extract_minimal_method(m::Core.Method, registry::TypeIDRegistry) → MinimalMethod

Pre-extract the fields from a Core.Method that typeinf needs.
"""
function extract_minimal_method(m::Core.Method, registry)
    sig_id = get_type_id(registry, m.sig)
    MinimalMethod(
        sig_id,
        Int32(m.nargs),
        Int32(m.isva ? 1 : 0),
        Int32(Base.hasgenerator(m) ? 1 : 0),
        reinterpret(Int64, UInt64(m.primary_world)),
    )
end

"""
    extract_minimal_method_match(mm, method_to_idx, registry) → MinimalMethodMatch

Pre-extract fields from a Core.MethodMatch.
"""
function extract_minimal_method_match(mm, method_to_idx::Dict{UInt, Int32}, registry)
    m = mm.method::Core.Method
    oid = objectid(m)
    method_idx = method_to_idx[oid]

    # spec_types may not be in the registry (intersection type)
    spec_id = get_type_id(registry, mm.spec_types)
    if spec_id < 0
        # Assign a new ID for this spec_types
        spec_id = assign_type!(registry, mm.spec_types)
    end

    MinimalMethodMatch(
        method_idx,
        Int32(mm.fully_covers ? 1 : 0),
        spec_id,
    )
end

"""
    extract_all_methods(table, registry::TypeIDRegistry) → MethodExtraction

Extract all Method and MethodMatch data from a DictMethodTable.
Returns a MethodExtraction with deduplicated methods and per-signature matches.
"""
function extract_all_methods(table, registry)
    methods = MinimalMethod[]
    method_to_idx = Dict{UInt, Int32}()
    matches_dict = Dict{Int32, Vector{MinimalMethodMatch}}()

    # First pass: collect all unique Method objects
    for (sig, result) in table.methods
        for match in result.matches
            m = match.method::Core.Method
            oid = objectid(m)
            if !haskey(method_to_idx, oid)
                idx = Int32(length(methods))
                method_to_idx[oid] = idx
                push!(methods, extract_minimal_method(m, registry))
            end
        end
    end

    # Second pass: extract matches per signature
    for (sig, result) in table.methods
        type_id = get_type_id(registry, sig)
        if type_id < 0
            continue
        end
        mm_list = MinimalMethodMatch[]
        for match in result.matches
            push!(mm_list, extract_minimal_method_match(match, method_to_idx, registry))
        end
        matches_dict[type_id] = mm_list
    end

    return MethodExtraction(methods, method_to_idx, matches_dict)
end

# ─── Verification ─────────────────────────────────────────────────────────────

"""
    verify_method(mm::MinimalMethod, m::Core.Method, registry) → Bool

Verify that MinimalMethod fields match native Core.Method fields.
"""
function verify_method(mm::MinimalMethod, m::Core.Method, registry)
    ok = true
    if mm.nargs != Int32(m.nargs)
        ok = false
    end
    if mm.isva != Int32(m.isva ? 1 : 0)
        ok = false
    end
    if mm.has_generator != Int32(Base.hasgenerator(m) ? 1 : 0)
        ok = false
    end
    expected_pw = reinterpret(Int64, UInt64(m.primary_world))
    if mm.primary_world != expected_pw
        ok = false
    end
    # sig_type_id: verify round-trip
    expected_sig_id = get_type_id(registry, m.sig)
    if mm.sig_type_id != expected_sig_id
        ok = false
    end
    return ok
end

"""
    verify_extraction(extraction, table, registry) → (n_verified, n_failed, failures)

Verify ALL extracted methods against their native Method objects.
"""
function verify_extraction(extraction::MethodExtraction, table, registry)
    n_verified = 0
    n_failed = 0
    failures = String[]

    # Build reverse map: method_idx → Method object
    idx_to_method = Dict{Int32, Core.Method}()
    for (sig, result) in table.methods
        for match in result.matches
            m = match.method::Core.Method
            oid = objectid(m)
            if haskey(extraction.method_to_idx, oid)
                idx = extraction.method_to_idx[oid]
                idx_to_method[idx] = m
            end
        end
    end

    for (idx, native_method) in idx_to_method
        mm = extraction.methods[idx + 1]  # 0-based → 1-based
        if verify_method(mm, native_method, registry)
            n_verified += 1
        else
            n_failed += 1
            push!(failures, "Method idx=$idx: $(native_method.name) in $(native_method.module)")
        end
    end

    return (n_verified=n_verified, n_failed=n_failed, failures=failures)
end

# ─── WasmGC Emission ──────────────────────────────────────────────────────────

"""
    emit_minimal_methods!(emitter::MethodTableEmitter, extraction::MethodExtraction)

Emit MinimalMethod data as WasmGC struct globals.
Creates a WasmGC struct type for MinimalMethod and emits each method as a constant global.
Returns a Vector{UInt32} mapping method_idx → WasmGC global index.
"""
function emit_minimal_methods!(emitter, extraction::MethodExtraction)
    mod = emitter.mod

    # Define MinimalMethod WasmGC struct type
    # Fields: sig_type_id (i32), nargs (i32), isva (i32), has_generator (i32),
    #         primary_world (i64)
    method_fields = FieldType[
        FieldType(I32, false),   # sig_type_id
        FieldType(I32, false),   # nargs
        FieldType(I32, false),   # isva
        FieldType(I32, false),   # has_generator
        FieldType(I64, false),   # primary_world
    ]
    method_type_idx = add_struct_type!(mod, method_fields)

    # Emit each MinimalMethod as a constant global
    global_indices = UInt32[]
    for mm in extraction.methods
        init_expr = UInt8[]

        # sig_type_id: i32
        push!(init_expr, Opcode.I32_CONST)
        append!(init_expr, encode_leb128_signed(mm.sig_type_id))

        # nargs: i32
        push!(init_expr, Opcode.I32_CONST)
        append!(init_expr, encode_leb128_signed(mm.nargs))

        # isva: i32
        push!(init_expr, Opcode.I32_CONST)
        append!(init_expr, encode_leb128_signed(mm.isva))

        # has_generator: i32
        push!(init_expr, Opcode.I32_CONST)
        append!(init_expr, encode_leb128_signed(mm.has_generator))

        # primary_world: i64
        push!(init_expr, Opcode.I64_CONST)
        append!(init_expr, encode_leb128_signed(mm.primary_world))

        # struct.new $method_type_idx
        push!(init_expr, Opcode.GC_PREFIX)
        push!(init_expr, Opcode.STRUCT_NEW)
        append!(init_expr, encode_leb128_unsigned(method_type_idx))

        global_idx = add_global_ref!(mod, method_type_idx, false, init_expr; nullable=false)
        push!(global_indices, global_idx)
    end

    return (method_type_idx=method_type_idx, global_indices=global_indices)
end
