# test_minimal_method.jl — Verify MinimalMethod/MinimalMethodMatch extraction
#
# PHASE-2A-004: Design minimal Method/MethodMatch WasmGC representation.
#
# Tests:
#   1. Extract MinimalMethod for 50+ methods — verify all fields match native
#   2. Extract MinimalMethodMatch — verify method_idx, fully_covers, spec_types
#   3. WasmGC emission — emit methods as struct globals, validate with wasm-tools
#   4. MethodExtraction round-trip — extract from DictMethodTable, verify all entries
#
# Run: julia +1.12 --project=. test/selfhost/test_minimal_method.jl

using Test
using WasmTarget

# Load typeinf infrastructure
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "dict_method_table.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "typeid_registry.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "method_table_emit.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "minimal_method.jl"))

# ─── Build test data ──────────────────────────────────────────────────────────
# Use a representative set of functions to populate a DictMethodTable

test_sigs = [
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(div), Int64, Int64},
    Tuple{typeof(rem), Int64, Int64},
    Tuple{typeof(abs), Int64},
    Tuple{typeof(sign), Int64},
    Tuple{typeof(+), Float64, Float64},
    Tuple{typeof(-), Float64, Float64},
    Tuple{typeof(*), Float64, Float64},
    Tuple{typeof(/), Float64, Float64},
    Tuple{typeof(sqrt), Float64},
    Tuple{typeof(abs), Float64},
    Tuple{typeof(isnan), Float64},
    Tuple{typeof(isinf), Float64},
    Tuple{typeof(convert), Type{Int64}, Float64},
    Tuple{typeof(convert), Type{Float64}, Int64},
    Tuple{typeof(string), Int64},
    Tuple{typeof(length), String},
    Tuple{typeof(length), Vector{Int64}},
    Tuple{typeof(push!), Vector{Int64}, Int64},
    Tuple{typeof(getindex), Vector{Int64}, Int64},
    Tuple{typeof(setindex!), Vector{Int64}, Int64, Int64},
    Tuple{typeof(size), Vector{Int64}},
    Tuple{typeof(isempty), Vector{Int64}},
    Tuple{typeof(first), Vector{Int64}},
    Tuple{typeof(last), Vector{Int64}},
    Tuple{typeof(min), Int64, Int64},
    Tuple{typeof(max), Int64, Int64},
    Tuple{typeof(clamp), Int64, Int64, Int64},
    Tuple{typeof(==), Int64, Int64},
    Tuple{typeof(<), Int64, Int64},
    Tuple{typeof(<=), Int64, Int64},
    Tuple{typeof(>), Int64, Int64},
    Tuple{typeof(>=), Int64, Int64},
    Tuple{typeof(!=), Int64, Int64},
    Tuple{typeof(&), Int64, Int64},
    Tuple{typeof(|), Int64, Int64},
    Tuple{typeof(xor), Int64, Int64},
    Tuple{typeof(<<), Int64, Int64},
    Tuple{typeof(>>), Int64, Int64},
    Tuple{typeof(>>>), Int64, Int64},
    Tuple{typeof(+), Int32, Int32},
    Tuple{typeof(*), Int32, Int32},
    Tuple{typeof(zero), Type{Int64}},
    Tuple{typeof(one), Type{Int64}},
    Tuple{typeof(typemax), Type{Int64}},
    Tuple{typeof(typemin), Type{Int64}},
    Tuple{typeof(sizeof), Type{Int64}},
    Tuple{typeof(trailing_zeros), Int64},
    Tuple{typeof(leading_zeros), Int64},
    Tuple{typeof(count_ones), Int64},
    Tuple{typeof(hash), Int64},
    Tuple{typeof(hash), String},
]

println("Building DictMethodTable with $(length(test_sigs)) test signatures...")
world = Base.get_world_counter()
native_mt = Core.Compiler.InternalMethodTable(world)

# Populate a simple DictMethodTable (non-transitive for speed)
table = DictMethodTable(world)
for sig in test_sigs
    result = Core.Compiler.findall(sig, native_mt; limit=3)
    if result !== nothing
        table.methods[sig] = result
    end
end
println("  Table populated: $(length(table.methods)) signatures")

# Build TypeID registry
registry = TypeIDRegistry()
assign_types!(registry, table)
println("  Registry: $(length(registry.type_to_id)) types registered")

# ─── Test 1: Extract individual MinimalMethod and verify fields ───────────────

@testset "MinimalMethod extraction — individual methods" begin
    n_methods_tested = 0
    for (sig, result) in table.methods
        for match in result.matches
            m = match.method::Core.Method
            mm = extract_minimal_method(m, registry)

            # Verify each field matches native
            @test mm.nargs == Int32(m.nargs)
            @test mm.isva == Int32(m.isva ? 1 : 0)
            @test mm.has_generator == Int32(Base.hasgenerator(m) ? 1 : 0)
            @test mm.primary_world == reinterpret(Int64, UInt64(m.primary_world))

            # sig_type_id round-trips
            expected_sig_id = get_type_id(registry, m.sig)
            @test mm.sig_type_id == expected_sig_id
            if expected_sig_id >= 0
                @test get_type(registry, expected_sig_id) == m.sig
            end

            n_methods_tested += 1
        end
    end
    @test n_methods_tested >= 50
    println("  Verified $n_methods_tested individual method extractions")
end

# ─── Test 2: Extract MinimalMethodMatch and verify fields ─────────────────────

@testset "MinimalMethodMatch extraction" begin
    n_matches_tested = 0
    # We need the method_to_idx mapping first
    extraction = extract_all_methods(table, registry)

    for (sig, result) in table.methods
        for match in result.matches
            m = match.method::Core.Method
            oid = objectid(m)
            @test haskey(extraction.method_to_idx, oid)

            mmatch = extract_minimal_method_match(match, extraction.method_to_idx, registry)

            # method_idx is valid
            @test mmatch.method_idx >= 0
            @test mmatch.method_idx < Int32(length(extraction.methods))

            # fully_covers matches native
            @test mmatch.fully_covers == Int32(match.fully_covers ? 1 : 0)

            # spec_types_type_id is valid
            @test mmatch.spec_types_type_id >= 0

            n_matches_tested += 1
        end
    end
    @test n_matches_tested >= 50
    println("  Verified $n_matches_tested method match extractions")
end

# ─── Test 3: Full MethodExtraction and verify_extraction ──────────────────────

@testset "MethodExtraction full verification" begin
    extraction = extract_all_methods(table, registry)

    # Basic structure checks
    @test length(extraction.methods) > 0
    @test length(extraction.method_to_idx) == length(extraction.methods)
    @test length(extraction.matches) > 0

    # Verify all methods
    result = verify_extraction(extraction, table, registry)
    @test result.n_failed == 0
    @test result.n_verified >= 50
    println("  Verified $(result.n_verified) methods, $(result.n_failed) failures")
    if result.n_failed > 0
        println("  Failures: $(result.failures)")
    end

    # Verify matches dict has entries for registered signatures
    for (sig, lookup_result) in table.methods
        type_id = get_type_id(registry, sig)
        if type_id >= 0
            @test haskey(extraction.matches, type_id)
            if haskey(extraction.matches, type_id)
                @test length(extraction.matches[type_id]) == length(lookup_result.matches)
            end
        end
    end
end

# ─── Test 4: WasmGC emission of MinimalMethod globals ────────────────────────

@testset "MinimalMethod WasmGC emission" begin
    extraction = extract_all_methods(table, registry)

    # Create a fresh WasmModule
    mod = WasmTarget.WasmModule()
    emitter = create_method_table_emitter(mod, registry)

    # Emit method table (MethodLookupResult globals)
    emit_method_table!(emitter, table)

    # Emit MinimalMethod globals
    result = emit_minimal_methods!(emitter, extraction)

    @test result.method_type_idx >= 0
    @test length(result.global_indices) == length(extraction.methods)
    @test length(result.global_indices) >= 50

    println("  Emitted $(length(result.global_indices)) MinimalMethod globals")
    println("  Method struct type index: $(result.method_type_idx)")

    # Build hash table and emit module to validate
    build_hash_table!(emitter)

    # Serialize and validate with wasm-tools
    bytes = WasmTarget.to_bytes(mod)
    @test length(bytes) > 0

    tmpfile = tempname() * ".wasm"
    write(tmpfile, bytes)
    println("  Module size: $(length(bytes)) bytes")

    # Validate with wasm-tools
    validate_result = try
        run(pipeline(`wasm-tools validate $tmpfile`, stderr=devnull))
        true
    catch
        false
    end
    @test validate_result
    if validate_result
        println("  wasm-tools validate: PASS")
    else
        println("  wasm-tools validate: FAIL")
    end
    rm(tmpfile; force=true)
end

# ─── Test 5: Method deduplication ─────────────────────────────────────────────

@testset "Method deduplication" begin
    extraction = extract_all_methods(table, registry)

    # Count total MethodMatch references vs unique methods
    total_refs = 0
    for (_, matches) in extraction.matches
        total_refs += length(matches)
    end

    # Many signatures share methods (e.g., +(::Int64, ::Int64) matches the same Base.+ Method)
    @test length(extraction.methods) <= total_refs
    println("  $(length(extraction.methods)) unique methods, $total_refs total match references")
end

# ─── Test 6: Edge cases ──────────────────────────────────────────────────────

@testset "MinimalMethod edge cases" begin
    # Test with a varargs method
    varargs_sig = Tuple{typeof(string), Vararg{Any}}
    varargs_result = Core.Compiler.findall(varargs_sig, native_mt; limit=3)
    if varargs_result !== nothing
        for match in varargs_result.matches
            m = match.method::Core.Method
            if m.isva
                mm = extract_minimal_method(m, registry)
                @test mm.isva == Int32(1)
                @test mm.nargs >= Int32(1)
                println("  Found varargs method: $(m.name), nargs=$(mm.nargs)")
                break
            end
        end
    end

    # Test that primary_world is positive for current methods
    for (sig, result) in table.methods
        for match in result.matches
            m = match.method::Core.Method
            mm = extract_minimal_method(m, registry)
            # Active methods have a positive primary_world
            @test mm.primary_world > 0
            break  # Just test one
        end
        break
    end
end

println("\n=== PHASE-2A-004: MinimalMethod tests complete ===")
