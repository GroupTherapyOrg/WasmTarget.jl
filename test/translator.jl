# dart2wasm's translator.dart, ported (src/translator.jl, dev/MARCH.md 1.A9 and 1.C): each filled
# definition answers as dart's does on fixed inputs.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

@testset "translator.dart: TranslatorOptions" begin
    local O = D.TranslatorOptions
    local o = O()
    # dart's field initializers
    @test o.optimization_level == 1 && o.generate_source_maps && o.unique_constant_names && !o.enable_asserts
    @test o.enable_unique_types === nothing && o.shared_memory_max_pages === nothing && o.watch_points == Int[]
    # each construction its own list, as dart's `= []` initializer
    push!(o.watch_points, 3)
    @test O().watch_points == Int[]
    # the getters: the override where set, else the optimization level's threshold
    @test D.inlining(o) && !D.minify(o) && !D.unique_types(o) && !D.omit_error_details(o)
    @test !D.omit_implicit_type_checks(o) && !D.omit_bounds_checks(o)
    local o4 = O(optimization_level = 4, minify_override = false)
    @test !D.minify(o4) && D.omit_bounds_checks(o4) && D.omit_error_details(o4) && D.unique_types(o4)
    @test !D.inlining(O(inlining_override = false))
end

module TranslatorCases
f_add(a::Int, b::Int) = a + b
end

@testset "translator.dart: the Translator, its queue and writeULEB128" begin
    local W = WasmTarget
    local t = D.Translator(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), D.TranslatorOptions(standalone = true))
    # the program is the closed world's NIR, the entry's body among it
    @test t.component isa Vector{W.NirBody} && !isempty(t.component)
    @test D.is_standalone(t) && !D.is_standalone(D.Translator(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), D.TranslatorOptions()))
    # a translator comes from a ClosedWorld alone, never from loose NIR bodies (audit M2)
    @test all(m -> any(p -> p === W.ClosedWorld, Base.unwrap_unionall(m.sig).parameters), methods(D.Translator))
    # the constructor's body builds the queue over the translator; drained empty, it does nothing
    local q = t.compilation_queue[]
    @test q.translator === t && D.is_empty(q)
    @test D.drain_completion_queue(t) === nothing && D.is_empty(q)
    local e = try; D.pop(q); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    # ULEB128, decoded by Julia's arithmetic: seven bits a byte, low first, the high bit continuing
    local uleb(v) = (io = IOBuffer(); D.write_uleb128(io, v); take!(io))
    local decode(bs) = sum(Int(b & 0x7f) << (7 * (k - 1)) for (k, b) in enumerate(bs))
    for v in Int64[0, 1, 127, 128, 255, 300, 16383, 16384, 2^35 + 11, typemax(Int64)]
        local bs = uleb(v)
        @test decode(bs) == v && all(b -> b & 0x80 != 0, bs[1:end-1]) && bs[end] & 0x80 == 0
        @test length(bs) == max(1, cld(64 - leading_zeros(v), 7))
    end
    @test uleb(624485) == UInt8[0xe5, 0x8e, 0x26]   # the LEB128 article's worked example
    local e2 = try; uleb(-1); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Internal
end

@testset "translator.dart: translateStorageType's located rejections" begin
    local W = WasmTarget
    local t = D.Translator(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), D.TranslatorOptions())
    # a UnionAll and a type as a value of a type Julia left open are no class: located rejections,
    # before any wasm type is made
    for ty in (Vector, Type{T} where T, AbstractVector{<:Integer})
        local e = try; D.translate_storage_type(t, ty); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Unquarantined
    end
    local e = try; D.translate_type(t, Base.unwrap_unionall(Type{T} where T)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unquarantined && occursin("type as a value", e.rejection.row)
    # the late top type and builtin types, read before collect, the classes unassigned
    local e2 = try; t.top_type[]; nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unported && occursin("Translator.classes", e2.rejection.anchor)
end

module TypeCases
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Square <: Shape; s::Float64; end
f_shapes(n::Int) = n > 0 ? Circle(1.0) : Square(2.0)
end

@testset "translator.dart: translateType over a class table" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local t = D.Translator(W.check_subset(TypeCases.f_shapes, (Int,), "translator"), D.TranslatorOptions())
    # the builtin types: Julia's primitive classes with a wasm representation
    for (T, w) in ((Bool, IR.NumType_i32), (Int32, IR.NumType_i32), (UInt32, IR.NumType_i32), (Char, IR.NumType_i32),
                   (Int64, IR.NumType_i64), (UInt64, IR.NumType_i64), (Float32, IR.NumType_f32), (Float64, IR.NumType_f64))
        @test D.translate_storage_type(t, T) == w && D.translate_type(t, T) == w
    end
    # the 8- and 16-bit integers stored packed, read as the zero-extended i32
    for (T, w) in ((Int8, IR.PackedType_i8), (UInt8, IR.PackedType_i8), (Int16, IR.PackedType_i16), (UInt16, IR.PackedType_i16))
        @test D.translate_storage_type(t, T) == w && D.translate_type(t, T) == IR.NumType_i32
    end
    # a primitive class with no wasm representation rejects, located
    for T in (Int128, Float16, Ptr{Nothing})
        local e = try; D.translate_type(t, T); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Unquarantined
    end
    # Union{} and Nothing are the nullable none reference; Union{} returned, the non-nullable one
    @test D.translate_type(t, Nothing) == IR.RefType_none(; nullable = true) == D.translate_type(t, Union{})
    @test D.translate_return_type(t, Union{}) == IR.RefType_none(; nullable = false)
    # a hand-made class table, as collect fills it: Any, the top type's place, Shape represented by
    # its own struct, and Int64's box
    local top = D.ClassInfo(nothing, 0, 0, IR.StructType("#Top"), nothing)
    local anyi = D.ClassInfo(Any, 5, 1, IR.StructType("Any"; super_type = top.struct_), top)
    local shape = D.ClassInfo(TypeCases.Shape, 4, 2, anyi.struct_, anyi)
    local int = D.ClassInfo(Int64, 3, 1, IR.StructType("Int64"; super_type = top.struct_), top)
    t.classes[] = [top]
    for info in (top, anyi, shape, int)
        info._repr = info.non_nullable_type
        info.cls === nothing || (t.class_info[info.cls] = info)
    end
    # Any is dart's Object?, the top type
    @test D.translate_type(t, Any) == top.nullable_type
    # a class is its representation; a Union of classes Julia's typejoin of its members
    @test D.translate_type(t, TypeCases.Shape) == shape.non_nullable_type
    @test typejoin(TypeCases.Circle, TypeCases.Square) === TypeCases.Shape
    @test D.translate_type(t, Union{TypeCases.Circle, TypeCases.Square}) == shape.non_nullable_type
    @test D.translate_type(t, Union{Nothing, TypeCases.Circle, TypeCases.Square}) == shape.nullable_type
    # a nullable primitive is its own class's box, nullable; unboxed it is the class's representation
    @test D.translate_type(t, Union{Nothing, Int64}) == int.nullable_type
    @test D.translate_storage_type(t, Int64; unbox = false) == int.non_nullable_type
    # a class with no class info is collect's gap: a located rejection
    local e = try; D.translate_type(t, TypeCases.Circle); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    # a field's type is its declared one
    local f = W.class_instance_fields(TypeCases.Circle, "translator")[1]
    @test D.type_of_field(t, f) === Float64 && D.translate_type_of_field(t, f) == IR.NumType_f64
end

module UnionCases
maybe(n::Int) = n > 0 ? 7 : nothing
either(n::Int) = n > 0 ? 1 : 2.5
end

@testset "translator.dart: translateType keeps a Union's values exact" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local t = D.Translator(W.check_subset(TypeCases.f_shapes, (Int,), "translator"), D.TranslatorOptions())
    local top = D.ClassInfo(nothing, 0, 0, IR.StructType("#Top"), nothing)
    local anyi = D.ClassInfo(Any, 6, 1, IR.StructType("Any"; super_type = top.struct_), top)
    local real = D.ClassInfo(Real, 5, 3, anyi.struct_, anyi)
    local int = D.ClassInfo(Int64, 1, 1, IR.StructType("Int64"; super_type = top.struct_), top)
    local flt = D.ClassInfo(Float64, 2, 1, IR.StructType("Float64"; super_type = top.struct_), top)
    t.classes[] = [top]
    for info in (top, anyi, int, flt)
        info._repr = info.non_nullable_type
        info.cls === nothing || (t.class_info[info.cls] = info)
    end
    # collect gives Real the upper bound of its primitive subclasses' infos, the top struct
    real._repr = D.repr(D._upper_bound(int, flt))
    t.class_info[Real] = real
    # Union{Nothing,T}: T's representation, nullable, `nothing` its null; native returns either
    @test only(Base.return_types(UnionCases.maybe, (Int,))) == Union{Nothing,Int64}
    @test UnionCases.maybe(-1) === nothing && UnionCases.maybe(1) === 7
    local m = D.translate_type(t, Union{Nothing,Int64})
    @test m == int.nullable_type && m.nullable
    @test D.translate_type(t, Int64) == IR.NumType_i64          # the T alone is unboxed
    # Union{Int64,Float64}: represented by Julia's typejoin, Real; each value keeps its own class,
    # the box of each a subtype of the representation, never the other's
    @test only(Base.return_types(UnionCases.either, (Int,))) == Union{Float64,Int64}
    @test typeof(UnionCases.either(1)) === Int64 && typeof(UnionCases.either(-1)) === Float64
    local u = D.translate_type(t, Union{Int64,Float64})
    @test typejoin(Int64, Float64) === Real && u == D.repr(real) && u isa IR.RefType
    @test W.WasmBuilder.is_subtype_of(int.non_nullable_type, u) && W.WasmBuilder.is_subtype_of(flt.non_nullable_type, u)
    @test !W.WasmBuilder.is_subtype_of(int.non_nullable_type, flt.non_nullable_type)
    # packing is storage alone: a Bool or an 8- or 16-bit integer value is i32
    for T in (Bool, Int8, UInt8, Int16, UInt16)
        @test D.translate_type(t, T) == IR.NumType_i32
    end
end
