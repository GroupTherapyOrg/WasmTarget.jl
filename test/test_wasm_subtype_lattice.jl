# Standalone unit tests for the `wasm_subtype` relation (src/builder/types.jl): the declared
# supertype chain, nullability, the non-null abstract references, function types.
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
        @test WT.wasm_subtype(WT.I32, WT.I32, mod.types)
        @test WT.wasm_subtype(WT.F64, WT.F64, mod.types)
        @test !WT.wasm_subtype(WT.I32, WT.I64, mod.types)   # numerics are invariant
        @test !WT.wasm_subtype(WT.I32, WT.F64, mod.types)
        @test !WT.wasm_subtype(WT.I32, WT.AnyRef, mod.types) # numeric is not a ref subtype
        @test WT.wasm_subtype(cref(2), cref(2), mod.types)   # === concrete
    end

    @testset "abstract GC hierarchy: any > eq > {struct, array, i31}" begin
        @test WT.wasm_subtype(WT.EqRef, WT.AnyRef, mod.types)
        @test WT.wasm_subtype(WT.StructRef, WT.EqRef, mod.types)
        @test WT.wasm_subtype(WT.ArrayRef, WT.EqRef, mod.types)
        @test WT.wasm_subtype(WT.I31Ref, WT.EqRef, mod.types)
        @test WT.wasm_subtype(WT.StructRef, WT.AnyRef, mod.types)
        # not subtypes (wrong direction / cross-branch)
        @test !WT.wasm_subtype(WT.AnyRef, WT.EqRef, mod.types)
        @test !WT.wasm_subtype(WT.EqRef, WT.StructRef, mod.types)
        @test !WT.wasm_subtype(WT.StructRef, WT.ArrayRef, mod.types)
        @test !WT.wasm_subtype(WT.StructRef, WT.I31Ref, mod.types)
        @test !WT.wasm_subtype(WT.ArrayRef, WT.StructRef, mod.types)
    end

    @testset "extern / func / exn own tops (disjoint)" begin
        @test WT.wasm_subtype(WT.ExternRef, WT.ExternRef, mod.types)
        @test WT.wasm_subtype(WT.FuncRef, WT.FuncRef, mod.types)
        @test !WT.wasm_subtype(WT.ExternRef, WT.AnyRef, mod.types)
        @test !WT.wasm_subtype(WT.AnyRef, WT.ExternRef, mod.types)
        @test !WT.wasm_subtype(WT.FuncRef, WT.AnyRef, mod.types)
        @test !WT.wasm_subtype(WT.ExternRef, WT.FuncRef, mod.types)
        @test !WT.wasm_subtype(WT.StructRef, WT.ExnRef, mod.types)
        @test !WT.wasm_subtype(WT.ExnRef, WT.AnyRef, mod.types)
    end

    @testset "F4 — concrete struct walks its declared supertype chain" begin
        # Leaf <: Mid <: Base nominally.
        @test WT.wasm_subtype(cref(2), cref(1), mod.types)   # Leaf <: Mid
        @test WT.wasm_subtype(cref(2), cref(0), mod.types)   # Leaf <: Base (transitive)
        @test WT.wasm_subtype(cref(1), cref(0), mod.types)   # Mid  <: Base
        @test WT.wasm_subtype(cref(2), cref(2), mod.types)   # reflexive
        # wrong direction is NOT a subtype.
        @test !WT.wasm_subtype(cref(0), cref(2), mod.types)  # Base ⊄ Leaf
        @test !WT.wasm_subtype(cref(1), cref(2), mod.types)  # Mid  ⊄ Leaf
        # unrelated concrete struct is NOT a subtype (the F4 bug fix: previously TRUE).
        @test !WT.wasm_subtype(cref(2), cref(3), mod.types)  # Leaf ⊄ Other
        @test !WT.wasm_subtype(cref(3), cref(0), mod.types)  # Other ⊄ Base
        @test !WT.wasm_subtype(cref(0), cref(3), mod.types)
    end

    @testset "F4 — concrete <: abstract super (struct/array → eq → any)" begin
        @test WT.wasm_subtype(cref(2), WT.StructRef, mod.types)  # Leaf <: struct
        @test WT.wasm_subtype(cref(2), WT.EqRef, mod.types)      # Leaf <: eq
        @test WT.wasm_subtype(cref(2), WT.AnyRef, mod.types)     # Leaf <: any
        @test WT.wasm_subtype(cref(4), WT.ArrayRef, mod.types)   # $Arr <: array
        @test WT.wasm_subtype(cref(4), WT.EqRef, mod.types)      # $Arr <: eq
        @test WT.wasm_subtype(cref(4), WT.AnyRef, mod.types)     # $Arr <: any
        # concrete struct is NOT <: array (and vice versa).
        @test !WT.wasm_subtype(cref(2), WT.ArrayRef, mod.types)
        @test !WT.wasm_subtype(cref(4), WT.StructRef, mod.types)
        # concrete struct is NOT <: i31.
        @test !WT.wasm_subtype(cref(2), WT.I31Ref, mod.types)
        # abstract <: concrete is false (an abstract value isn't a specific concrete).
        @test !WT.wasm_subtype(WT.StructRef, cref(2), mod.types)
        @test !WT.wasm_subtype(WT.AnyRef, cref(0), mod.types)
    end

    @testset "P2 — nullability: nullable source ⊄ non-null target" begin
        # Identical heap type, only nullability differs.
        @test  WT.wasm_subtype(cref(2, false), cref(2, true), mod.types)  # non-null <: nullable (ok)
        @test !WT.wasm_subtype(cref(2, true),  cref(2, false), mod.types)  # nullable ⊄ non-null (P2)
        @test  WT.wasm_subtype(cref(2, false), cref(2, false), mod.types)  # non-null <: non-null (===)
        @test  WT.wasm_subtype(cref(2, true),  cref(2, true), mod.types)  # nullable <: nullable (===)
        # Along the supertype chain with nullability.
        @test  WT.wasm_subtype(cref(2, false), cref(0, false), mod.types)  # non-null Leaf <: non-null Base
        @test !WT.wasm_subtype(cref(2, true),  cref(0, false), mod.types)  # nullable Leaf ⊄ non-null Base (P2)
        @test  WT.wasm_subtype(cref(2, true),  cref(0, true), mod.types)  # nullable Leaf <: nullable Base
        # Abstract nullable-shorthand (enum refs are nullable) into a non-null abstract target.
        @test !WT.wasm_subtype(WT.StructRef, WT.NonNullExternRef, mod.types)  # cross-hierarchy anyway
    end

    @testset "B6 — NonNullAbstractRef participates by heap type (no MethodError)" begin
        # (ref extern) and (ref func) — non-null abstract tops.
        @test  WT.wasm_subtype(WT.NonNullExternRef, WT.ExternRef, mod.types)  # non-null extern <: nullable extern
        @test !WT.wasm_subtype(WT.ExternRef, WT.NonNullExternRef, mod.types)  # nullable ⊄ non-null (P2)
        @test  WT.wasm_subtype(WT.NonNullExternRef, WT.NonNullExternRef, mod.types)  # ===
        @test  WT.wasm_subtype(WT.NonNullFuncRef, WT.FuncRef, mod.types)
        @test !WT.wasm_subtype(WT.NonNullExternRef, WT.FuncRef, mod.types)    # extern ⊄ func
        # A non-null abstract GC ref (ref struct) resolves to the struct heap kind.
        nn_struct = WT.NonNullAbstractRef(UInt8(WT.StructRef))
        nn_any    = WT.NonNullAbstractRef(UInt8(WT.AnyRef))
        @test  WT.wasm_subtype(nn_struct, WT.StructRef, mod.types)  # non-null struct <: nullable struct
        @test  WT.wasm_subtype(nn_struct, nn_any, mod.types)        # non-null struct <: non-null any
        @test  WT.wasm_subtype(cref(2, false), nn_struct, mod.types)  # non-null Leaf <: (ref struct)
        @test !WT.wasm_subtype(cref(2, true),  nn_struct, mod.types)  # nullable Leaf ⊄ (ref struct) (P2)
        @test !WT.wasm_subtype(nn_struct, WT.NonNullAbstractRef(UInt8(WT.ArrayRef)), mod.types)  # struct ⊄ array
    end
end

# The operand-stack validator asks `wasm_subtype` over its module's types at every pop.
@testset "the validator types every pop by wasm_subtype over its module" begin
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

    # a type index the module does not define is invalid, never guessed a struct
    @test_throws WT.ModuleValidationError WT.wasm_subtype(cref(99, false), WT.StructRef, mod.types)
end

# function types: a defined function type is a subtype of itself and of func only, never of
# another function type or of a type outside the func hierarchy (dart DefType.isSubtypeOf walks
# superType ?? abstractSuperType, a function type's abstract super being func)
@testset "function types are subtypes of func and of themselves only" begin
    mod = _build_chain_module()
    f = WT.add_type!(mod, WT.FuncType(WT.WasmValType[], WT.WasmValType[WT.I32]))
    g = WT.add_type!(mod, WT.FuncType(WT.WasmValType[], WT.WasmValType[WT.I64]))
    @test  WT.wasm_subtype(cref(f, false), cref(f, true), mod.types)
    @test  WT.wasm_subtype(cref(f, false), WT.FuncRef, mod.types)
    @test  WT.wasm_subtype(cref(f, true), WT.FuncRef, mod.types)
    @test !WT.wasm_subtype(cref(f), cref(g), mod.types)
    @test !WT.wasm_subtype(WT.FuncRef, cref(f), mod.types)
    @test !WT.wasm_subtype(cref(f), WT.AnyRef, mod.types)
    @test !WT.wasm_subtype(cref(f), WT.StructRef, mod.types)
    @test !WT.wasm_subtype(cref(0), cref(f), mod.types)
    # the non-null exn reference is a subtype of the nullable one
    @test  WT.wasm_subtype(WT.NonNullAbstractRef(UInt8(WT.ExnRef)), WT.ExnRef, mod.types)
end

# A cast's operand and target share a hierarchy (not a subtype check).
@testset "_wt_same_hierarchy (a cast's operand and target)" begin
    mod = _build_chain_module()

    # Within the `any` hierarchy: abstract↔abstract, abstract↔concrete, and two UNRELATED
    # concretes are all same-hierarchy (the last is a valid-but-always-trapping cast — the
    # key case a subtype check would wrongly reject).
    @test  WT._wt_same_hierarchy(WT.AnyRef, WT.StructRef, mod.types)
    @test  WT._wt_same_hierarchy(WT.AnyRef, cref(2), mod.types)
    @test  WT._wt_same_hierarchy(cref(2), cref(3), mod.types)      # $Leaf vs unrelated $Other — same hierarchy
    @test  WT._wt_same_hierarchy(cref(2), cref(4), mod.types)      # struct vs array — both under `any`
    @test  WT._wt_same_hierarchy(WT.EqRef, WT.I31Ref, mod.types)
    # Cross-hierarchy: any/func/extern/exn are disjoint tops.
    @test !WT._wt_same_hierarchy(WT.AnyRef, WT.ExternRef, mod.types)
    @test !WT._wt_same_hierarchy(WT.AnyRef, WT.FuncRef, mod.types)
    @test !WT._wt_same_hierarchy(WT.FuncRef, WT.ExternRef, mod.types)
    @test !WT._wt_same_hierarchy(cref(2), WT.FuncRef, mod.types)   # GC struct vs func
    @test !WT._wt_same_hierarchy(WT.ExnRef, WT.AnyRef, mod.types)
    # Numerics aren't ref types — never same-hierarchy.
    @test !WT._wt_same_hierarchy(WT.I32, WT.AnyRef, mod.types)

    # Validator integration: a cross-hierarchy ref.cast is REJECTED (the externref → GC
    # struct PURE-323 pattern — codegen must extern.convert_any first); a within-hierarchy
    # downcast (anyref → concrete struct) is accepted.
    bbad = WT.InstrBuilder(WT.WasmValType[WT.ExternRef], WT.WasmValType[]; func_name="cast-bad", mod=mod)
    WT.local_get!(bbad, 0)
    @test_throws WT.StackImbalanceError WT.ref_cast!(bbad, 2, false)
    bok = WT.InstrBuilder(WT.WasmValType[WT.AnyRef], WT.WasmValType[]; func_name="cast-ok", mod=mod)
    WT.local_get!(bok, 0); WT.ref_cast!(bok, 2, false)
    @test bok.v.stack == WT.WasmValType[cref(2, false)]
end
