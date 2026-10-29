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
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions(standalone = true))
    # the program is the closed world's NIR, the entry's body among it
    @test t.component isa W.NirWorld && !isempty(t.component.bodies)
    @test D.is_standalone(t) && !D.is_standalone(D.Translator(WasmTarget.build_nir(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions()))
    # a translator comes from a NirWorld alone, the typestate build_nir makes from a ClosedWorld, never
    # from loose NIR bodies (audit M2)
    @test all(m -> any(p -> p === W.NirWorld, Base.unwrap_unionall(m.sig).parameters), methods(D.Translator))
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
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    # a UnionAll and a type as a value of a type Julia left open are no class: located rejections,
    # before any wasm type is made
    for ty in (Vector, AbstractVector{<:Integer})
        local e = try; D.translate_storage_type(t, ty); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Unquarantined
    end
    # a type as a value of a type Julia left open (`Type`, `Type{T}`) is the open Type{T} above every
    # kind, supertype(DataType): its class info comes from collect, missing here, a located rejection
    for ty in (Type, Base.unwrap_unionall(Type{T} where T))
        local e = try; D.translate_type(t, ty); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Internal && occursin(string(supertype(DataType)), e.rejection.site)
    end
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
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(TypeCases.f_shapes, (Int,), "translator"), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(TypeCases.f_shapes, (Int,), "translator"), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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

module ModuleCases
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Square <: Shape; s::Float64; n::Int32; end
shapes(n::Int) = n > 0 ? Circle(Float64(n)) : Square(2.0, Int32(7))
end

@testset "translator.dart, modules.dart: one module, then collect over a real program" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    # the monolithic output data: one main module, named by its id and the output file
    local opts = D.WasmCompilerOptions(; main_uri = "", output_file = "out/prog.wasm")
    local data = D.build_module_output_data(D.DefaultModuleStrategy(opts))
    @test length(data.modules) == 1 && D.main_module(data).is_main && !D.has_multiple_modules(data)
    @test D.main_module(data).module_import_name == "M" && D.main_module(data).module_name == "prog.wasm"
    @test sprint(show, D.main_module(data)) == "M"
    @test D.WasmCompilerOptions_module_name_for_id("out/prog.wasm", 3) == "prog_module3.wasm"
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(ModuleCases.shapes, (Int,), "translator"), "test"), data, D.TranslatorOptions())
    local e = try; D.main_module(t); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    D._init_modules(t, nothing)
    local m = D.main_module(t)
    @test D.modules(t) == [m] && D.is_main_module(t, m) && D.name_for_module(t, m) == "M" && !D.has_multiple_modules(t)
    @test D.types_builder(t) === m.types[] && t.module_to_builder[m.module_] === m
    # collect: every class of the closed world gets its info, the structs below #Top
    local c = D.ClassInfoCollector(t)
    collect(c)
    local numbering = t.class_id_numbering[]
    @test all(cls -> haskey(t.class_info, cls), numbering.dfs_order)
    @test t.classes[][1] === c.top_info[] && t.classes_supers_first[][1] === c.top_info[]
    # Any is dart's Object: the class id, then the identity hash; a struct's own fields follow, each
    # its Julia field's wasm type, immutable as Julia's struct is
    local anyi = t.class_info[Any]
    @test [f.type for f in anyi.struct_.fields] == [IR.NumType_i32, IR.NumType_i32]
    local sq = t.class_info[ModuleCases.Square]
    @test [f.type for f in sq.struct_.fields] == [IR.NumType_i32, IR.NumType_i32, IR.NumType_f64, IR.NumType_i32]
    @test sq.struct_.field_names[2] == "s" && sq.struct_.field_names[3] == "n" && !sq.struct_.fields[3].mutable
    @test t.field_index[W.class_instance_fields(ModuleCases.Square, "t")[2]] == 3
    # the abstract Shape shares Any's struct; its representation is the upper bound of Circle and
    # Square, both below Any
    local shape = t.class_info[ModuleCases.Shape]
    @test shape.struct_ === anyi.struct_ && D.repr(shape) == anyi.non_nullable_type
    # a primitive class sits below the top struct: the class id and its value
    local int32 = t.class_info[Int32]
    @test int32.super_info === c.top_info[] && [f.type for f in int32.struct_.fields] == [IR.NumType_i32, IR.NumType_i32]
    # every class's ranges and representations are set, none cyclic
    @test all(info -> !D.is_cyclic(info), t.classes_supers_first[])
    # translateType now reads the class table collect filled
    @test D.translate_type(t, ModuleCases.Shape) == anyi.non_nullable_type
    @test D.translate_type(t, Union{Nothing,Int32}) == int32.nullable_type
end

@testset "translator.dart: the code generator's helpers" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(ModuleCases.shapes, (Int,), "translator"), "test"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local mi = Core.Compiler.specialize_method(Base._which(Base.signature_type(ModuleCases.shapes, (Int,))))
    # Julia checks no parameter on entry; a member's parameter info is made once
    @test !D.need_to_check_types_for(t, mi) && !D._need_to_check_types_for(t, mi)
    @test !D.need_to_check_parameter(t, W.NirArgument(2); unchecked_entry = false) && D.can_skip_implicit_check(t, W.NirArgument(2))
    @test !D.need_to_check_type_parameter(t, TypeVar(:T))
    # a superclass is on Julia's supertype chain, never the class itself
    @test D._has_superclass(t, ModuleCases.Square, ModuleCases.Shape) && D._has_superclass(t, ModuleCases.Square, Any)
    @test !D._has_superclass(t, ModuleCases.Shape, ModuleCases.Shape) && !D._has_superclass(t, Any, Any)
    @test !D.need_to_check_implicit_setter_value(t, W.class_instance_fields(ModuleCases.Square, "t")[1]; unchecked_entry = false)
    # one entry, the member's own, and no entry check; a call's single target is the MethodInstance
    # Julia resolved it to, none for a call it left to a builtin
    @test D.get_function_entry(t, mi; unchecked_entry = true) === mi === D.get_function_entry(t, mi; unchecked_entry = false)
    local inv = W.NirInvoke(mi, W.NirValue[W.NirConst(Core.Const(ModuleCases.shapes)), W.NirArgument(2)])
    @test D.can_use_unchecked_entry(t, W.NirArgument(2), inv)
    @test D.single_target(t, inv) === mi && D.single_target(t, W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.tuple))])) === nothing
    # a type's most specific class: a Union's join, nullable with `nothing`; a type value's kind
    @test D.to_most_specific_interface_type(t, Union{Nothing,ModuleCases.Circle,ModuleCases.Square}) == Union{Nothing,ModuleCases.Shape}
    @test D.class_for_type(t, Union{ModuleCases.Circle,ModuleCases.Square}) === ModuleCases.Shape && D.class_for_type(t, Type{Int64}) === DataType
    @test D.class_for_type(t, Nothing) === Any && D.class_for_type(t, Union{Int64,Nothing}) === Int64
    # Julia's wasm types are its wasm arrays; at the boundary a reference is translateExternalType's
    @test D.is_wasm_type(t, W.WasmArray{Int64}) && D.is_wasm_type(t, W.ImmutableWasmArray{Any}) && !D.is_wasm_type(t, Int64)
    @test D.translate_external_storage_type(t, Any) == IR.RefType_any(; nullable = true)
    local ex = try; D.translate_external_storage_type(t, Int64); nothing; catch x; x; end
    @test ex isa W.RejectionError && ex.rejection isa W.Internal
    # the parameters an entry check would test: the arguments after the callee, of the specialization's types
    local pc = D.get_parameters_to_check(t, mi)
    @test pc.positional == [W.NirArgument(2)] && pc.positional_to_type_check == Type[Int] && isempty(pc.type_parameters) && isempty(pc.named)
    @test D._types_from_type_parameter_bounds(t, [TypeVar(:T, Integer)]) == Type[Integer]
    # a single closure target holds its call target and parameter info
    local sct = D.SingleClosureTarget__(D.direct_call_target(t, mi), D.param_info_for_direct_call(t, mi))
    @test sct.call_target isa D.AstCallTarget && sct.param_info === D.param_info_for_direct_call(t, mi)
    # deferred loading is out of scope, and a Julia method declares no pragmas: located rejections
    local el = try; D.encode_load_list(t, D.ModuleMetadata[]); nothing; catch x; x; end
    @test el isa W.RejectionError && el.rejection isa W.Internal && occursin("deferred loading", el.rejection.site)
    # TFA's inferred-type readers: Julia's inference typed every value, so none is read, located
    local et = try; D._inferred_type_of_return_value(t, mi); nothing; catch x; x; end
    @test et isa W.RejectionError && et.rejection isa W.Internal
    # a member's return type is its body's, looked up by nir_body_of: a member with none rejects, located
    @test D.type_of_return_value(t, mi) === Union{ModuleCases.Circle, ModuleCases.Square}
    local other = Core.Compiler.specialize_method(Base._which(Base.signature_type(sin, (Float64,))))
    local eo = try; D.type_of_return_value(t, other); nothing; catch x; x; end
    @test eo isa W.RejectionError && eo.rejection isa W.Internal
    local p = D.param_info_for_direct_call(t, mi)
    @test p === D.param_info_for_direct_call(t, mi) && p.positional == [nothing]
    # a parameter or local takes the wasm type of the Julia type inferred for it
    @test D.translate_type_of_parameter(t, Int, true) == IR.NumType_i64
    @test D.translate_type_of_local_variable(t, Int32) == IR.NumType_i32
    @test D.translate_type_of_local_variable(t, ModuleCases.Shape) == D.repr(t.class_info[ModuleCases.Shape])
    # no output is the void marker, one is itself
    local void = t.void_marker[]
    @test D.output_or_void(t, IR.ValueType[]) === void && D.output_or_void(t, IR.ValueType[IR.NumType_i32]) == IR.NumType_i32
    local e = try; D.output_or_void(t, IR.ValueType[IR.NumType_i32, IR.NumType_i64]); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    # conversions: none between equal types, across the void marker, by subtyping
    @test !D.needs_conversion(t, IR.NumType_i32, IR.NumType_i32) && D.needs_conversion(t, IR.NumType_i32, void)
    local sq = t.class_info[ModuleCases.Square]
    local shape = D.repr(t.class_info[ModuleCases.Shape])
    @test !D.needs_conversion(t, sq.non_nullable_type, shape) && D.needs_conversion(t, shape, sq.non_nullable_type)
    local m = D.main_module(t)
    local b = W.WasmBuilder.InstructionsBuilder(m, IR.ValueType[shape], IR.ValueType[sq.non_nullable_type])
    W.WasmBuilder.local_get(b, b.locals[1])
    D.convert_type(t, b, shape, shape)                       # equal: nothing emitted
    local n = length(b._instructions)
    D.convert_type(t, b, shape, sq.non_nullable_type)        # downcast: one ref.cast, accepted by the builder
    @test length(b._instructions) == n + 1
    # boxing needs the value's Julia class: a located rejection here
    local e2 = try; D.convert_type(t, b, IR.NumType_i32, shape); nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Unquarantined && occursin("1.D", e2.rejection.row)
end

module FirstCases
f(x::Int32) = x + Int32(1)
nothing_or(n::Int) = n > 0 ? n : nothing
end

# dart's wasm:export is Julia's @ccallable: a declared member of the closed world is exported beside
# the entry
module CCallableCases
Base.@ccallable function twice(x::Int32)::Int32
    @noinline
    return x * Int32(2)
end
entry(x::Int32) = twice(x) + Int32(1)
end

@testset "functions.dart: the exports, the entry and every @ccallable member" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local world = W.check_subset(CCallableCases.entry, (Int32,), "translator")
    local t = D.Translator(W.build_nir(world, "test"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local fc = t.functions[]
    local entry = only(b.ci.def for b in t.component if b.ci.def.def.name === :entry)
    local twice = only(b.ci.def for b in t.component if b.ci.def.def.name === :twice)
    @test D.get_export_name(fc, entry) == "entry" && D.get_export_name(fc, twice) == "twice"
    D._collect_imports_and_exports(fc)
    # both strong exports: each a function now, exported under its name, called from the host
    for (mi, name) in ((entry, "entry"), (twice, "twice"))
        local fn = D.get_existing_function(fc, mi)
        @test fn !== nothing && fn.is_js_called && fn.exported_name[] == name
    end
    # the ccallable's declared signature is the specialization Julia compiled, its return within it
    @test only(methods(CCallableCases.twice)).ccallable[2] == twice.specTypes
    # the reached ccallable was queued beside the entry as juliac queues it, its record the verifier's
    @test only(methods(CCallableCases.twice)).ccallable in world.codeinfos
    # a declared return inference does not meet, queued through the same inference and verifier: a
    # located OutsideSubset, the verifier's own error
    local bad = Core.svec(UInt8, only(methods(CCallableCases.twice)).ccallable[2])
    local e = try; W._infer_verified(Any[world.entry, bad], Base.get_world_counter(), "translator: bad ccallable"); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.OutsideSubset && e.at == "translator: bad ccallable"
    @test only(e.rejection.errors).kind === W.ccallable_return_mismatch
end

@testset "functions.dart: a member's function, its type and its queued code" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(FirstCases.f, (Int32,), "translator"), "test"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local mi = only(b.ci.def for b in t.component if b.ci.def.def.name === :f)
    # the return type is Julia's inferred one
    @test D.type_of_return_value(t, mi) === only(Base.return_types(FirstCases.f, (Int32,))) === Int32
    local fc = t.functions[]
    @test D.get_existing_function(fc, mi) === nothing
    # the function type: the arguments after the singleton callee, then the return, Julia's types' wasm types
    local ft = D.get_function_type(fc, mi)
    @test ft.inputs == [IR.NumType_i32] && ft.outputs == [IR.NumType_i32]
    # the types builder makes one function type per signature: the same type each time
    @test D.signature_for_direct_call(t, mi) === ft
    local fn = D.get_function(fc, mi)
    @test D.get_function(fc, mi) === fn && D.get_existing_function(fc, mi) === fn
    @test fn.type === ft && fn.function_name == "$(parentmodule(FirstCases.f)).f(::Int32)"
    @test fn.inline_hint === nothing && !fn.is_pure
    # defined in the main module and queued once for its code generator
    @test fn.enclosing_module === D.main_module(t).module_
    local q = t.compilation_queue[]
    @test length(q._pending) == 1 && only(q._pending) isa D.AstCompilationTask && only(q._pending).reference === mi
    # a member returning nothing or an Int: not a null-only return, so it returns its nullable box
    local t2 = D.Translator(WasmTarget.build_nir(W.check_subset(FirstCases.nothing_or, (Int,), "translator"), "test"), data, D.TranslatorOptions())
    D._init_modules(t2, nothing)
    collect(D.ClassInfoCollector(t2))
    local mi2 = only(b.ci.def for b in t2.component if b.ci.def.def.name === :nothing_or)
    @test !D.synthesize_null_return_value(t2.functions[], mi2) && !D.synthesize_no_return(t2.functions[], mi2)
    @test D.get_function_type(t2.functions[], mi2).outputs == [t2.class_info[Int64].nullable_type]
    @test D.InliningDecision(true, "small").should_inline
end

module GlobalCases
typed_global::Int32 = Int32(3)
untyped_global = 4
end

@testset "translator.dart: the collaborators, the importers and a static field's type" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(FirstCases.f, (Int32,), "translator"), "test"), data, D.TranslatorOptions())
    # the constructor's body builds each ported collaborator over the translator
    @test t.class_info_collector[].translator === t && t.types[] isa D.Types && t.closure_layouter[] isa D.ClosureLayouter
    @test t.cross_module_function_table[].translator === t && t.table_based_globals[] isa D.TableBasedGlobals
    @test t.export_namer.minify == D.minify(t.options) && isempty(t.linking_actions)
    D._init_modules(t, nothing)
    local m = D.main_module(t)
    # one module: an importer answers a definition with itself, exporting nothing
    local table = t.cross_module_function_table[]
    local wt = D.get_wasm_table(table, m)
    @test wt === table._defined_wasm_table[] && wt.enclosing_module === m.module_ && !D.has(table._imported_wasm_tables, wt)
    @test isempty(D.imports(table._imported_wasm_tables))
    # a static field is a global binding, its type the binding's declared one
    @test D.type_of_field(t, GlobalRef(GlobalCases, :typed_global)) === Int32 === Core.get_binding_type(GlobalCases, :typed_global)
    @test D.translate_type_of_field(t, GlobalRef(GlobalCases, :typed_global)) == IR.NumType_i32
    @test D.type_of_field(t, GlobalRef(GlobalCases, :untyped_global)) === Any
end

module UndefCases
mutable struct M; a::Base.RefValue{Int}; b::Int; M() = new(); end
mk() = M()
end

@testset "translator.dart: a field Julia may leave undefined is nullable; Type values" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(UndefCases.mk, (), "translator"), "test"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    # Julia's own answer: new() assigns none of M's fields, and `a` is then undefined
    @test Core.Compiler.datatype_min_ninitialized(UndefCases.M) == 0 && !isdefined(UndefCases.M(), :a)
    local a, b = W.class_instance_fields(UndefCases.M, "t")
    @test D.translate_type_of_field(t, a).nullable                       # a reference past the count
    @test D.translate_type_of_field(t, b) == IR.NumType_i64              # a bits field, never undefined
    # the emitCodegen defect at the pin, fixed at its source: codegen is emitted when it is the last phase
    local o = D.WasmCompilerOptions_default_options()
    o.phases = [D.CompilerPhase_cfe, D.CompilerPhase_tfa, D.CompilerPhase_codegen]
    @test D.emit_codegen(o) && !D.emit_tfa(o)
end

@testset "translator.dart: translate, the first program end to end" begin
    local W = WasmTarget
    local B = W.WasmBuilder
    local IR = B.IR
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(FirstCases.f, (Int32,), "translator"), "test"), data, D.TranslatorOptions(print_kernel = true))
    # printKernel: each member's header, function type, signature and its NIR statements, printed
    local mods, printed = mktemp() do path, io
        local m = redirect_stdout(() -> D.translate(t, nothing), io)
        flush(io)
        (m, read(path, String))
    end
    @test occursin("(exported as f)", printed) && occursin(", Int32}", printed) && occursin("  %1 = ", printed)
    # one module, the main one, built by the builder that validated every instruction (D10)
    @test length(mods) == 1 && only(keys(mods)).is_main
    local m = only(values(mods))
    @test m isa IR.Module
    # the entry exported under its function's name, its type the external (i32) -> (i32)
    local mi = t.component.entry
    local fn = D.get_existing_function(t.functions[], mi)
    @test fn !== nothing && fn.is_js_called && fn.type.inputs == [IR.NumType_i32] && fn.type.outputs == [IR.NumType_i32]
    @test D.get_export_name(t.functions[], mi) == "f"
    # its code generated: the queue drained; the dispatch tables empty (D32)
    @test D.is_empty(t.compilation_queue[]) && isempty(t.dispatch_table[]._table[])
    local s = B.Serializer(); B.serialize(s, m)
    @test length(B.data(s)) > 8 && B.data(s)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
end

@testset "translator.dart: array types and dummy values" begin
    local W = WasmTarget
    local B = W.WasmBuilder
    local IR = B.IR
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(ModuleCases.shapes, (Int,), "translator"), "test"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    # one array type per element storage type and mutability, its element the storage type
    local a = D.wasm_array_type(t, IR.NumType_i64, "Int64")
    @test D.wasm_array_type(t, IR.NumType_i64, "Int64") === a && a.element_type[].type == IR.NumType_i64 && a.element_type[].mutable
    @test D.wasm_array_type(t, IR.NumType_i64, "Int64"; mutable_ = false) !== a
    # an array of a primitive class holds its boxes, not its numbers
    @test D.array_type_for_dart_type(t, Int32; mutable_ = true).element_type[].type == t.class_info[Int32].non_nullable_type
    # dummy values: zero, null, a heap type's global; one trapping function per signature
    local m = D.main_module(t)
    local dv = D.get_dummy_values_collector_for_module(t, m)
    @test D.get_dummy_values_collector_for_module(t, m) === dv
    local sq = t.class_info[ModuleCases.Square]
    local b = B.InstructionsBuilder(m, IR.ValueType[], IR.ValueType[IR.NumType_i32, sq.nullable_type, sq.non_nullable_type])
    D.instantiate_local_dummy_value(dv, b, IR.NumType_i32)
    D.instantiate_local_dummy_value(dv, b, sq.nullable_type)
    D.instantiate_local_dummy_value(dv, b, sq.non_nullable_type)
    @test length(dv._dummy_values) == 1 && haskey(dv._dummy_values, sq.struct_)
    B.var"end"(b)                                  # the builder accepts the three values as its outputs
    local ft = B.define_function(m.types[], IR.ValueType[IR.NumType_i32], IR.ValueType[])
    local df = D.get_dummy_function(dv, ft)
    @test D.get_dummy_function(dv, ft) === df && D.is_dummy_function(dv, df)
    # makeArray: each item pushed, then array.new_fixed, the reference the builder accepts as the output
    local ab = B.InstructionsBuilder(m, IR.ValueType[], IR.ValueType[IR.RefType_def(a; nullable = false)])
    @test D.make_array(t, ab, a, 3, (et, i) -> (@assert et == IR.NumType_i64; B.i64_const(ab, i))) == IR.RefType_def(a; nullable = false)
    @test [typeof(x) for x in ab._instructions] == [IR.I64Const, IR.I64Const, IR.I64Const, IR.ArrayNewFixed]
    B.var"end"(ab)
    # definitions Julia never reaches reject, Internal, naming Julia's replacement: dart:ffi's memory,
    # a pragma'd memory, the loading map's lazy getters
    local internal(f) = (e = try; f(); nothing; catch x; x; end; e isa W.RejectionError && e.rejection isa W.Internal)
    @test internal(() -> D.ffi_memory(t, m)) && internal(() -> D.find_memory(t, t.component.entry, m))
    @test internal(() -> D._replace_body(t, D.get_dummy_function(D.get_dummy_values_collector_for_module(t, m), B.define_function(m.types[], IR.ValueType[], IR.ValueType[]))))
    # Julia has no WasmTable class, so no field is a table
    @test D.get_table(t, m, W.class_instance_fields(ModuleCases.Square, "t")[1]) === nothing
end

@testset "translator.dart: the Translator holds every field dart declares" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    # dart's Translator declares 95 instance fields (translator.dart:98 to :1682); 14 are Julia's
    # answers (libraries, coreTypes, typeEnvironment, hierarchy, subtypes, index, recordClasses and
    # TFA's 7 metadata maps) and 1 is out of scope (loadingMap, deferred loading): 95 - 14 - 1 = 80
    @test fieldcount(D.Translator) == 80
    # DummyValuesCollector declares 5 (translator.dart:3832 to :3841), each held
    @test fieldcount(D.DummyValuesCollector) == 5
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(ModuleCases.shapes, (Int,), "translator"), "test"), data, D.TranslatorOptions(optimization_level = 2))
    @test all(i -> isdefined(t, i), 1:fieldcount(D.Translator))
    # the initializer list: the symbols minified as the options say
    @test t.symbols isa D.Symbols && t.symbols.minify == D.minify(t.options) == true
    # the constructor's body builds the exception tags over the translator, as dart's does
    @test t._exception_tags[].translator === t
    # a late field whose class is not ported yet is read before its assignment: Unported, at its line
    for (f, line) in ((:interop_member_namer, 164), (:stack_trace_info, 243), (:record_info, 244),
                      (:list_array_type, 249), (:boxed_int_type, 267), (:boxed_double_type, 271), (:stack_trace_type, 285),
                      (:stack_trace_type_nullable, 285), (:invocation_type, 309), (:boxed_classes, 374), (:box_classes, 380),
                      (:value_classes, 389))
        local e = try; getfield(t, f)[]; nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Unported && occursin("translator.dart:$line ", e.rejection.anchor)
    end
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local m = D.main_module(t)
    # dart's Object is Any; Object? Any, the nullable object array's element the top type
    @test t.object_info[] === t.class_info[Any]
    local oa = t.nullable_object_array_type[]
    @test oa.element_type[].type == t.top_type[] && oa.element_type[].mutable && oa === D.array_type_for_dart_type(t, Any; mutable_ = true)
    @test t.nullable_object_array_type_ref[] == IR.RefType_def(oa; nullable = false)
    # the importers, each over the translator with dart's prefix
    @test t._imported_field_tables[]._translator === t && t._imported_field_tables[]._export_prefix == "fieldTable"
    @test t._imported_memories[]._translator === t && t._imported_memories[]._export_prefix == "memory"
    # the caches start empty; the dummy struct global is late, never assigned at the pin
    @test isempty(t.function_ref_cache) && isempty(t.constructor_closures) && isempty(t._member_closures) && isempty(t._need_to_check)
    local e = try; D.get_dummy_values_collector_for_module(t, m).dummy_struct_global[]; nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unported && occursin("translator.dart:3841 ", e.rejection.anchor)
    # the per-module and per-member helpers, each made once: dynamic dispatchers, the exception tag, a
    # member's closures, a function's reference global
    @test D.get_dynamic_dispatchers_for_module(t, m) === D.get_dynamic_dispatchers_for_module(t, m)
    # a polymorphic dispatcher and a partial instantiation: no Julia program makes either, Internal
    local internal(f) = (e = try; f(); nothing; catch x; x; end; e isa W.RejectionError && e.rejection isa W.Internal)
    @test internal(() -> D.get_polymorphic_dispatchers_for_module(t, m)) && internal(() -> D.get_partial_instantiator_for_module(t, m))
    @test D.get_dart_exception_tag(t, m) isa IR.Tag && D.get_dart_exception_tag(t, m) === D.get_dart_exception_tag(t, m)
    local mi = t.component.entry
    @test D.get_closures(t, mi) === D.get_closures(t, mi) && D.get_closures(t, mi; find_captures = false) !== D.get_closures(t, mi)
    local f = D.get_dummy_function(D.get_dummy_values_collector_for_module(t, m), W.WasmBuilder.define_function(m.types[], IR.ValueType[], IR.ValueType[]))
    local g = D.make_function_ref(t, f)
    @test g === D.make_function_ref(t, f) && g.type == IR.GlobalType(IR.RefType_def(f.type; nullable = false); mutable = false)
    # a JS string's imported global: a Julia String is no JS string, Internal
    @test internal(() -> D.get_internalized_string_global(t, m, "hi"))
    # a record's class is its own tuple type's, a class of the closed world; one the world lacks rejects
    local er = try; D.get_record_class_info(t, Tuple{Int8,Int8}); nothing; catch x; x; end
    @test er isa W.RejectionError && er.rejection isa W.Internal
end

@testset "subset.jl, nir.jl: the closed world carries its entry" begin
    local W = WasmTarget
    local w = W.check_subset(FirstCases.f, (Int32,), "translator")
    local nir = W.build_nir(w, "translator")
    # the entry is the MethodInstance Julia's trim inference was asked for, carried, not positional
    @test w.entry === nir.entry && nir.entry.def === which(FirstCases.f, (Int32,))
    @test any(b -> b.ci.def === nir.entry, nir)
end

module InlineCases
@noinline h(x::Int) = x * 3
g(x::Int) = h(x) + h(x + 1)
@inline k(x::Int) = x + 1
end

@testset "translator.dart: the inlining decision, Julia's" begin
    local W = WasmTarget
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(InlineCases.g, (Int,), "translator"), "test"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local mi(f, T) = Core.Compiler.specialize_method(Base._which(Base.signature_type(f, T)))
    local h = mi(InlineCases.h, (Int,))
    local sig = D.get_function_type(t.functions[], t.component.entry)
    # @noinline never; @inline its preference; any other call Julia's inliner left stays a call
    @test !D.should_inline(t, h, sig).should_inline && D.should_inline(t, h, sig).reason == "@noinline"
    @test D.should_inline(t, mi(InlineCases.k, (Int,)), sig).should_inline
    @test !D.should_inline(t, t.component.entry, sig).should_inline
    @test !D.should_inline(D.Translator(WasmTarget.build_nir(W.check_subset(InlineCases.g, (Int,), "t"), "test"), data, D.TranslatorOptions(inlining_override = false)), h, sig).should_inline
    # a member being generated is not inlined into itself
    @test D.supports_inlining(t, h)
    push!(t.members_being_generated, h)
    @test !D.supports_inlining(t, h)
    @test !D.synthesize_null_return_value(t, t.component.entry) && !D.synthesize_no_return(t, t.component.entry)
    # dart's node count is Julia's inliner's decision: the counter is never made, located
    local en = try; D.NodeCounter(t); nothing; catch x; x; end
    @test en isa WasmTarget.RejectionError && en.rejection isa WasmTarget.Internal && occursin("ssa_inlining_pass", en.rejection.site)
    local ec = try; D._should_inline_constructor_call(t, h, sig, h); nothing; catch x; x; end
    @test ec isa WasmTarget.RejectionError && ec.rejection isa WasmTarget.Internal && occursin("ssa_inlining_pass", ec.rejection.site)
end
