# Standalone unit tests for the hardened `wasm_subtype` lattice (dart2wasm-parity
# Loop A: gaps F4 supertype-chain, P2 nullability, B6 NonNullAbstractRef).
#
# Mirrors dart2wasm pkg/wasm_builder/lib/src/ir/type.dart:
#   RefType.isSubtypeOf (nullable && !other.nullable → false; then heapType.isSubtypeOf)
#   DefType.isSubtypeOf (walk declared superType chain, then abstractSuperType)
#   the abstract hierarchy: any > eq > {struct, array, i31}; extern/func own tops.
#
# Run standalone:
#   julia --project=. test/test_wasm_subtype_lattice.jl

using WasmTarget
using Test

const WT = WasmTarget

# Build a module whose `types` lay out a known supertype chain.
#   idx 0: $Base    (struct (field i32))                         supertype = none
#   idx 1: $Mid     (sub $Base (struct (field i32)(field i32)))  supertype = 0
#   idx 2: $Leaf    (sub $Mid  (struct (field i32)(field i64)))  supertype = 1
#   idx 3: $Other   (struct (field f64))                         supertype = none (unrelated)
#   idx 4: $Arr     (array (mut i32))                            (an array, no supertype)
function _build_chain_module()
    mod = WT.WasmModule()
    push!(mod.types, WT.StructType([WT.FieldType(WT.I32, false)], nothing))                                   # 0 $Base
    push!(mod.types, WT.StructType([WT.FieldType(WT.I32, false), WT.FieldType(WT.I32, true)], UInt32(0)))     # 1 $Mid <: $Base
    push!(mod.types, WT.StructType([WT.FieldType(WT.I32, false), WT.FieldType(WT.I64, true)], UInt32(1)))     # 2 $Leaf <: $Mid
    push!(mod.types, WT.StructType([WT.FieldType(WT.F64, false)], nothing))                                   # 3 $Other (unrelated)
    push!(mod.types, WT.ArrayType(WT.FieldType(WT.I32, true)))                                                # 4 $Arr
    return mod
end

# Concrete-ref shorthands (nullable by default; pass nullable=false for non-null).
cref(i, nullable=true) = WT.ConcreteRef(UInt32(i), nullable)

@testset "wasm_subtype hardened lattice (dart2wasm parity)" begin
    mod = _build_chain_module()

    @testset "reflexivity / numerics-invariant" begin
        @test WT.wasm_subtype(WT.I32, WT.I32, mod)
        @test WT.wasm_subtype(WT.F64, WT.F64, mod)
        @test !WT.wasm_subtype(WT.I32, WT.I64, mod)   # numerics are invariant
        @test !WT.wasm_subtype(WT.I32, WT.F64, mod)
        @test !WT.wasm_subtype(WT.I32, WT.AnyRef, mod) # numeric is not a ref subtype
        @test WT.wasm_subtype(cref(2), cref(2), mod)   # === concrete
    end

    @testset "abstract GC hierarchy: any > eq > {struct, array, i31}" begin
        @test WT.wasm_subtype(WT.EqRef, WT.AnyRef, mod)
        @test WT.wasm_subtype(WT.StructRef, WT.EqRef, mod)
        @test WT.wasm_subtype(WT.ArrayRef, WT.EqRef, mod)
        @test WT.wasm_subtype(WT.I31Ref, WT.EqRef, mod)
        @test WT.wasm_subtype(WT.StructRef, WT.AnyRef, mod)
        # not subtypes (wrong direction / cross-branch)
        @test !WT.wasm_subtype(WT.AnyRef, WT.EqRef, mod)
        @test !WT.wasm_subtype(WT.EqRef, WT.StructRef, mod)
        @test !WT.wasm_subtype(WT.StructRef, WT.ArrayRef, mod)
        @test !WT.wasm_subtype(WT.StructRef, WT.I31Ref, mod)
        @test !WT.wasm_subtype(WT.ArrayRef, WT.StructRef, mod)
    end

    @testset "extern / func / exn own tops (disjoint)" begin
        @test WT.wasm_subtype(WT.ExternRef, WT.ExternRef, mod)
        @test WT.wasm_subtype(WT.FuncRef, WT.FuncRef, mod)
        @test !WT.wasm_subtype(WT.ExternRef, WT.AnyRef, mod)
        @test !WT.wasm_subtype(WT.AnyRef, WT.ExternRef, mod)
        @test !WT.wasm_subtype(WT.FuncRef, WT.AnyRef, mod)
        @test !WT.wasm_subtype(WT.ExternRef, WT.FuncRef, mod)
        @test !WT.wasm_subtype(WT.StructRef, WT.ExnRef, mod)
        @test !WT.wasm_subtype(WT.ExnRef, WT.AnyRef, mod)
    end

    @testset "F4 — concrete struct walks its declared supertype chain" begin
        # Leaf <: Mid <: Base nominally.
        @test WT.wasm_subtype(cref(2), cref(1), mod)   # Leaf <: Mid
        @test WT.wasm_subtype(cref(2), cref(0), mod)   # Leaf <: Base (transitive)
        @test WT.wasm_subtype(cref(1), cref(0), mod)   # Mid  <: Base
        @test WT.wasm_subtype(cref(2), cref(2), mod)   # reflexive
        # wrong direction is NOT a subtype.
        @test !WT.wasm_subtype(cref(0), cref(2), mod)  # Base ⊄ Leaf
        @test !WT.wasm_subtype(cref(1), cref(2), mod)  # Mid  ⊄ Leaf
        # unrelated concrete struct is NOT a subtype (the F4 bug fix: previously TRUE).
        @test !WT.wasm_subtype(cref(2), cref(3), mod)  # Leaf ⊄ Other
        @test !WT.wasm_subtype(cref(3), cref(0), mod)  # Other ⊄ Base
        @test !WT.wasm_subtype(cref(0), cref(3), mod)
    end

    @testset "F4 — concrete <: abstract super (struct/array → eq → any)" begin
        @test WT.wasm_subtype(cref(2), WT.StructRef, mod)  # Leaf <: struct
        @test WT.wasm_subtype(cref(2), WT.EqRef, mod)      # Leaf <: eq
        @test WT.wasm_subtype(cref(2), WT.AnyRef, mod)     # Leaf <: any
        @test WT.wasm_subtype(cref(4), WT.ArrayRef, mod)   # $Arr <: array
        @test WT.wasm_subtype(cref(4), WT.EqRef, mod)      # $Arr <: eq
        @test WT.wasm_subtype(cref(4), WT.AnyRef, mod)     # $Arr <: any
        # concrete struct is NOT <: array (and vice versa).
        @test !WT.wasm_subtype(cref(2), WT.ArrayRef, mod)
        @test !WT.wasm_subtype(cref(4), WT.StructRef, mod)
        # concrete struct is NOT <: i31.
        @test !WT.wasm_subtype(cref(2), WT.I31Ref, mod)
        # abstract <: concrete is false (an abstract value isn't a specific concrete).
        @test !WT.wasm_subtype(WT.StructRef, cref(2), mod)
        @test !WT.wasm_subtype(WT.AnyRef, cref(0), mod)
    end

    @testset "P2 — nullability: nullable source ⊄ non-null target" begin
        # Identical heap type, only nullability differs.
        @test  WT.wasm_subtype(cref(2, false), cref(2, true),  mod)  # non-null <: nullable (ok)
        @test !WT.wasm_subtype(cref(2, true),  cref(2, false), mod)  # nullable ⊄ non-null (P2)
        @test  WT.wasm_subtype(cref(2, false), cref(2, false), mod)  # non-null <: non-null (===)
        @test  WT.wasm_subtype(cref(2, true),  cref(2, true),  mod)  # nullable <: nullable (===)
        # Along the supertype chain with nullability.
        @test  WT.wasm_subtype(cref(2, false), cref(0, false), mod)  # non-null Leaf <: non-null Base
        @test !WT.wasm_subtype(cref(2, true),  cref(0, false), mod)  # nullable Leaf ⊄ non-null Base (P2)
        @test  WT.wasm_subtype(cref(2, true),  cref(0, true),  mod)  # nullable Leaf <: nullable Base
        # Abstract nullable-shorthand (enum refs are nullable) into a non-null abstract target.
        @test !WT.wasm_subtype(WT.StructRef, WT.NonNullExternRef, mod)  # cross-hierarchy anyway
    end

    @testset "B6 — NonNullAbstractRef participates by heap type (no MethodError)" begin
        # (ref extern) and (ref func) — non-null abstract tops.
        @test  WT.wasm_subtype(WT.NonNullExternRef, WT.ExternRef, mod)  # non-null extern <: nullable extern
        @test !WT.wasm_subtype(WT.ExternRef, WT.NonNullExternRef, mod)  # nullable ⊄ non-null (P2)
        @test  WT.wasm_subtype(WT.NonNullExternRef, WT.NonNullExternRef, mod)  # ===
        @test  WT.wasm_subtype(WT.NonNullFuncRef, WT.FuncRef, mod)
        @test !WT.wasm_subtype(WT.NonNullExternRef, WT.FuncRef, mod)    # extern ⊄ func
        # A non-null abstract GC ref (ref struct) resolves to the struct heap kind.
        nn_struct = WT.NonNullAbstractRef(UInt8(WT.StructRef))
        nn_any    = WT.NonNullAbstractRef(UInt8(WT.AnyRef))
        @test  WT.wasm_subtype(nn_struct, WT.StructRef, mod)  # non-null struct <: nullable struct
        @test  WT.wasm_subtype(nn_struct, nn_any, mod)        # non-null struct <: non-null any
        @test  WT.wasm_subtype(cref(2, false), nn_struct, mod)  # non-null Leaf <: (ref struct)
        @test !WT.wasm_subtype(cref(2, true),  nn_struct, mod)  # nullable Leaf ⊄ (ref struct) (P2)
        @test !WT.wasm_subtype(nn_struct, WT.NonNullAbstractRef(UInt8(WT.ArrayRef)), mod)  # struct ⊄ array
    end
end

# ── Loop A (FINISH) GATE: the LIVE operand-stack validator now uses `wasm_subtype`
#    (not the deleted permissive `wasm_types_assignable`) with the threaded `mod`.
#    Byte-identity can't catch this — the validator records errors silently in non-strict
#    mode — so this test asserts the relation actually fires at a `validate_pop!`, AND
#    proves WHY `mod` must be threaded (the `mod===nothing` path FALSE-REJECTS valid
#    concrete upcasts, which is the silent degradation the reorientation critique flagged).
@testset "Loop A — validator uses wasm_subtype with threaded mod" begin
    mod = _build_chain_module()

    # A bad ConcreteRef flow is REJECTED (records an error). $Other (idx 3) ⊄ $Base (idx 0).
    v = WT.WasmStackValidator(; func_name="gate", mod=mod)
    WT.validate_push!(v, cref(3, false))            # push $Other (non-null)
    WT.validate_pop!(v, cref(0, false))             # expect $Base — Other ⊄ Base ⇒ error
    @test WT.has_errors(v)

    # A valid upcast is ACCEPTED (no error). $Leaf (idx 2) <: $Base (idx 0).
    v2 = WT.WasmStackValidator(; func_name="gate", mod=mod)
    WT.validate_push!(v2, cref(2, false))           # push $Leaf
    WT.validate_pop!(v2, cref(0, false))            # expect $Base — Leaf <: Base ⇒ OK
    @test !WT.has_errors(v2)

    # Cross-kind reject: a concrete array (idx 4) is not a struct.
    v3 = WT.WasmStackValidator(; func_name="gate", mod=mod)
    WT.validate_push!(v3, cref(4, false))           # push $Arr
    WT.validate_pop!(v3, WT.StructRef)              # array ⊄ struct ⇒ error
    @test WT.has_errors(v3)

    # WHY mod must be threaded: with mod===nothing the concrete supertype chain can't be
    # resolved, so the SAME valid Leaf<:Base upcast is FALSE-REJECTED (spurious error).
    # Sound (never a false-accept) but noisy — hence the codegen ref-flowing builders
    # (compile_statement / generate_*_flow) pass ctx.mod. Numeric-only builders (int128)
    # never push a ConcreteRef, so their mod===nothing validators never hit this path.
    vno = WT.WasmStackValidator(; func_name="gate-no-mod", mod=nothing)
    WT.validate_push!(vno, cref(2, false))          # push $Leaf
    WT.validate_pop!(vno, cref(0, false))           # mod===nothing ⇒ chain unresolved ⇒ spurious error
    @test WT.has_errors(vno)
end
