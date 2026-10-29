# The closed world's classes (src/julia/classes.jl, dev/MARCH.md 1.C): the types the NIR carries, in
# the order the walk first meets them, each with its supertype chain to Any, a type as a value by
# its kind, a UnionAll value a located rejection. The class-id numbering reads this list
# (class_info.dart:864, its model dev/formal/ClassIdNumbering.tla).
using Test
using WasmTarget

module ClassesCases
struct Pt; x::Float64; y::Int32; end
f_arith(a::Int, b::Int) = a < b ? a + b : a * b
f_struct(n::Int) = n > 0 ? Pt(1.0, Int32(n)) : nothing
f_vector(v::Vector{Int}) = sum(v)
# a field of the UnionAll type Vector: the entry is concrete (an entry typed Vector has no compileable
# specialization, so Julia's subset check rejects it first), the value the walk meets is not
struct Open; v::Vector; end
f_open(o::Open) = length(o.v)
@enum Hue red blue
f_enum(c::Hue) = c == red ? 1 : 2
end

const W = WasmTarget
_classes(f, at) = W.closed_world_classes(W.build_nir(W.check_subset(f, at, "classes"), "classes"), "classes")

@testset "the closed world's classes (1.C)" begin
    # the kinds are Julia's own
    @test all(k -> Base.iskindtype(k) && isconcretetype(k), W._KINDS)
    for (f, at) in ((ClassesCases.f_arith, (Int, Int)), (ClassesCases.f_struct, (Int,)),
                    (ClassesCases.f_vector, (Vector{Int},)), (ClassesCases.f_enum, (ClassesCases.Hue,)))
        local cs = _classes(f, at)
        # each class once by identity (Julia's TypeofBottom and its supertype Type{Union{}} are
        # distinct objects Julia calls equal types, two classes), Any among them, every class's
        # supertype a class: one tree rooted at Any
        @test length(Base.IdSet{DataType}(cs)) == length(cs)
        @test Any in cs
        @test all(c -> supertype(c) in cs, cs)
        # the program's first argument, the callable, is met first
        @test first(cs) === typeof(f)
    end
    # program order: the arguments before the statements' types, a struct's fields after it
    local cs = _classes(ClassesCases.f_struct, (Int,))
    @test cs[1:4] == [typeof(ClassesCases.f_struct), Function, Any, Int64]
    @test findfirst(==(ClassesCases.Pt), cs) < findfirst(==(Float64), cs)
    @test ClassesCases.Pt in cs && Int32 in cs && Nothing in cs
    # a type as a value is met by its kind: throw_inexacterror's `Type` argument brings every kind
    @test all(k -> k in cs, W._KINDS)
    @test Type{Union{}} in cs              # TypeofBottom's supertype, as Julia gives it
    # a parametric instance is a class of its own, its supertype chain Julia's
    local vs = _classes(ClassesCases.f_vector, (Vector{Int},))
    @test Vector{Int} in vs && DenseVector{Int} in vs && AbstractVector{Int} in vs && Memory{Int} in vs
    @test !(Vector in vs)
    # an @enum is a class under its Enum supertype
    @test ClassesCases.Hue in _classes(ClassesCases.f_enum, (ClassesCases.Hue,))
    # a value of a UnionAll type not under Type rejects, located at the walk
    local e = try; _classes(ClassesCases.f_open, (ClassesCases.Open,)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unquarantined && occursin("src/julia/classes.jl", e.rejection.row)
end

module ClassesTypeValueCases
f_type(::Type{T}) where {T} = T
f_vec_eltype(n::Int) = n > 0 ? Vector{Int} : Vector{Float64}
end

@testset "classes: a type value brings the classes it denotes" begin
    local W = WasmTarget
    local cs(f, at) = W.closed_world_classes(W.build_nir(W.check_subset(f, at, "classes"), "classes"), "classes")
    # Type{Int8}: its kind, DataType, and Int8 itself, whose class id a type value's layout holds
    local c = cs(ClassesTypeValueCases.f_type, (Type{Int8},))
    @test DataType in c && Int8 in c
    # a Union of type values: each member it can denote
    local c2 = cs(ClassesTypeValueCases.f_vec_eltype, (Int,))
    @test Vector{Int} in c2 && Vector{Float64} in c2
end

module ClassesConstantCases
const CELL = Ref(0)
bump(n::Int) = (CELL[] += n; CELL[])
changing = 1
is_a(x::Symbol) = x === :a
end

@testset "classes: a constant's class, never a name's or a callee's" begin
    local W = WasmTarget
    local nw = W.build_nir(W.check_subset(ClassesConstantCases.bump, (Int,), "classes"), "classes")
    # the constant binding's value is read and written through its field; its class is no argument's or
    # statement's type, only the operand's (nir_value_type)
    @test !any(b -> any(t -> t === Base.RefValue{Int64}, b.types), nw)
    local reads = [(b, v) for b in nw for st in b.stmts for v in W.nir_value_operands(st) if v isa Union{W.NirConst,W.NirGlobal}]
    @test any(((b, v),) -> W.nir_value_type(b, v) === Base.RefValue{Int64}, reads)
    local cs = W.closed_world_classes(nw, "classes")
    @test Base.RefValue{Int64} in cs && Int64 in cs
    # a field builtin's field name and an intrinsic callee name what the call acts on: no class of theirs
    @test !(Symbol in cs) && !(Core.IntrinsicFunction in cs) && !(typeof(Core.getfield) in cs)
    for b in nw, st in b.stmts
        st isa W.NirCall && W.nir_callee(st) === Core.getfield || continue
        local vals = W.nir_value_operands(st)                       # the object, never the field's name
        @test st.args[2] in vals && !any(v -> v isa W.NirConst && v.c.val isa Symbol, vals)
    end
    # a Symbol a builtin takes as data is a value: `x === :a`'s operand, read from the program, and
    # tuple's element; one naming a field or a memory ordering is not
    local sym = W.build_nir(W.check_subset(ClassesConstantCases.is_a, (Symbol,), "classes"), "classes")
    local eq = only(st for b in sym for st in b.stmts if st isa W.NirCall && W.nir_callee(st) === Core.:(===))
    @test W.NirConst(Core.Const(:a)) in W.nir_value_operands(eq)
    local r = W.NirArgument(2)
    @test W.nir_value_operands(W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.tuple)), W.NirConst(Core.Const(:k)), r])) ==
        W.NirValue[W.NirConst(Core.Const(:k)), r]
    @test W.nir_value_operands(W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.memoryrefget)), r,
        W.NirConst(Core.Const(:not_atomic)), W.NirConst(Core.Const(false))])) == W.NirValue[r, W.NirConst(Core.Const(false))]
    @test W.nir_value_operands(W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.setfield!)), r, W.NirConst(Core.Const(:x)),
        W.NirConst(Core.Const(:v)), W.NirConst(Core.Const(:release))])) == W.NirValue[r, W.NirConst(Core.Const(:v))]
    # a global builtin names its binding by the module and the name together: neither a value
    @test W.nir_value_operands(W.NirCall(W.NirValue[W.NirConst(Core.Const(Core.setglobal!)), W.NirConst(Core.Const(Main)),
        W.NirConst(Core.Const(:counter)), r])) == W.NirValue[r]
    # get_binding_type names a binding by module and name; Base's getproperty, a generic function, takes
    # its Symbol as a value (Core's own getproperty is getfield)
    local cv(x) = W.NirConst(Core.Const(x))
    @test W.nir_value_operands(W.NirCall(W.NirValue[cv(Core.get_binding_type), cv(Main), cv(:counter)])) == W.NirValue[]
    @test W.nir_value_operands(W.NirCall(W.NirValue[cv(Base.getproperty), r, cv(:f)])) == W.NirValue[r, cv(:f)]
    # an allocation's type is its target
    local x = W.NirConst(Core.Const(1))
    @test W.nir_value_operands(W.NirNew(W.NirValue[W.NirConst(Core.Const(Base.RefValue{Int})), x])) == [x]
    # a read of a binding that can change is its static field's getter, not ported: Unported there, the
    # kind and site visitStaticGet rejects the read at
    local e = try; W.nir_value_type(first(nw), W.NirGlobal(GlobalRef(ClassesConstantCases, :changing))); nothing; catch y; y; end
    @test e isa W.RejectionError && e.rejection isa W.Unported && occursin("_generateGetter", e.rejection.anchor)
end

module SymbolCases
sym(x::Int) = x > 0 ? :pos : :neg
end

@testset "a Symbol is dart's Symbol class: its name, one String" begin
    # Julia holds a symbol's name outside its fields; its class's one field is the name, a String at
    # index 0, as dart's Symbol._name, and a closed world meeting Symbol meets String with it
    @test W.class_instance_fields(Symbol, "classes") == [W.ClassField(Symbol, 0, "_name", String, false)]
    local cs = _classes(SymbolCases.sym, (Int,))
    @test Symbol in cs && String in cs
end

module ModuleCases
# a TypeError holds a GlobalRef in its context's Union, and a GlobalRef its module
@noinline te(x::Int) = TypeError(:typeassert, "", Int, x)
# a module as a value
pick(x::Int) = x > 0 ? Base : Core
end

@testset "a Module's class is its name, one Symbol, Julia's jl_module_t's leading field" begin
    # Julia holds a module's data outside its fields; its class's one field is the name, a Symbol at
    # index 0, and a closed world meeting Module meets Symbol and String with it
    @test fieldcount(Module) == 0 && nameof(ModuleCases) === :ModuleCases
    @test W.class_instance_fields(Module, "classes") == [W.ClassField(Module, 0, "name", Symbol, false)]
    local cs = _classes(ModuleCases.te, (Int,))
    @test TypeError in cs && GlobalRef in cs && Module in cs && Symbol in cs && String in cs
    # class_info.dart's collector lays the class out: its struct, the object header and then the name
    local D = W.Dart2Wasm
    local t = D.Translator(W.build_nir(W.check_subset(ModuleCases.pick, (Int,), "classes"), "classes"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    local mod_info = t.class_info[Module]
    @test t.field_index[only(W.class_instance_fields(Module, "classes"))] == length(mod_info.struct_.fields) - 1
end

isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))

module EmptyMutableCases
mutable struct Token end
@noinline make(x::Int) = x > 0 ? Token() : nothing
made(x::Int) = make(x) isa Token
end

@testset "a mutable struct with no fields holds nothing, each instance its own object" begin
    # Julia's layout: no field and nothing outside one; identity is the object's (=== tells two apart)
    @test fieldcount(EmptyMutableCases.Token) == 0 && !Base.issingletontype(EmptyMutableCases.Token)
    @test W.class_instance_fields(EmptyMutableCases.Token, "classes") == W.ClassField[]
    @test EmptyMutableCases.Token in _classes(EmptyMutableCases.made, (Int,))
    local f = EmptyMutableCases.made
    local bytes = W.compile(f, (Int,))
    for r in WTRunner.run_cases([WTRunner.RunCase("made$(a)", bytes, a, f(a...)) for a in [(1,), (0,), (-2,)]])
        @test r.ok || (@info r.label r.why; false)
    end
end

module ConstantGraphCases
# a constant whose field, declared Any, holds a Float64: the Float64 only the value tells
mutable struct Box; v::Any; end
const B = Box(2.5)
boxed(x::Int) = x > 0 ? B : nothing
# a type as a value, its parameters' classes held by its layout
params() = Tuple{Int8,String}
end

@testset "a constant's object graph brings its values' classes (dev/formal/ValueClasses.tla)" begin
    # Julia's answer: each value a constant holds has its own class, typeof, which its declared field
    # type (Any) does not tell; constants.jl instantiates each, so the closed world numbers each
    local cs = _classes(ConstantGraphCases.boxed, (Int,))
    @test ConstantGraphCases.Box in cs && Float64 in cs
    @test W.compile(ConstantGraphCases.boxed, (Int,))[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    # a type value's own fields: DataType's parameters, an svec of the classes the type names
    local ps = _classes(ConstantGraphCases.params, ())
    @test DataType in ps && Core.SimpleVector in ps && Int8 in ps && String in ps
end
