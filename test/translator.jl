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
    local t = D.Translator(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions(standalone = true))
    # the program is the closed world's NIR, the entry's body among it
    @test t.component isa W.NirWorld && !isempty(t.component.bodies)
    @test D.is_standalone(t) && !D.is_standalone(D.Translator(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions()))
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
    local t = D.Translator(W.check_subset(TranslatorCases.f_add, (Int, Int), "translator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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
    local t = D.Translator(W.check_subset(TypeCases.f_shapes, (Int,), "translator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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
    local t = D.Translator(W.check_subset(TypeCases.f_shapes, (Int,), "translator"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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
    local t = D.Translator(W.check_subset(ModuleCases.shapes, (Int,), "translator"), data, D.TranslatorOptions())
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
    local t = D.Translator(W.check_subset(ModuleCases.shapes, (Int,), "translator"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local mi = Core.Compiler.specialize_method(Base._which(Base.signature_type(ModuleCases.shapes, (Int,))))
    # Julia checks no parameter on entry; a member's parameter info is made once
    @test !D.need_to_check_types_for(t, mi)
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
    local t = D.Translator(W.check_subset(CCallableCases.entry, (Int32,), "translator"), data, D.TranslatorOptions())
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
end

@testset "functions.dart: a member's function, its type and its queued code" begin
    local W = WasmTarget
    local IR = W.WasmBuilder.IR
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(W.check_subset(FirstCases.f, (Int32,), "translator"), data, D.TranslatorOptions())
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
    local t2 = D.Translator(W.check_subset(FirstCases.nothing_or, (Int,), "translator"), data, D.TranslatorOptions())
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
    local t = D.Translator(W.check_subset(FirstCases.f, (Int32,), "translator"), data, D.TranslatorOptions())
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
    local t = D.Translator(W.check_subset(UndefCases.mk, (), "translator"), data, D.TranslatorOptions())
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
    local t = D.Translator(W.check_subset(FirstCases.f, (Int32,), "translator"), data, D.TranslatorOptions())
    local mods = D.translate(t, nothing)
    # one module, the main one, built by the builder that validated every instruction (D10)
    @test length(mods) == 1 && only(keys(mods)).is_main
    local m = only(values(mods))
    @test m isa IR.Module
    # the entry exported under its function's name, its type the external (i32) -> (i32)
    local mi = first(t.component).ci.def
    local fn = D.get_existing_function(t.functions[], mi)
    @test fn !== nothing && fn.is_js_called && fn.type.inputs == [IR.NumType_i32] && fn.type.outputs == [IR.NumType_i32]
    @test D.get_export_name(t.functions[], mi) == "f"
    # its code generated: the queue drained; the dispatch tables empty (D32)
    @test D.is_empty(t.compilation_queue[]) && isempty(t.dispatch_table[]._table[])
    local s = B.Serializer(); B.serialize(s, m)
    @test length(B.data(s)) > 8 && B.data(s)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
end
