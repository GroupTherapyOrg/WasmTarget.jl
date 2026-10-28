# dart2wasm's types.dart, ported (src/types.jl): Julia's types as values and the is and as checks,
# Julia's subtyping the ground truth for every answer.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

module TypesCases
f_int32(n::Int) = Int32(n)
end

# a checker for the checkers' shared helpers, which read nothing of their checker
struct TypesCasesChecker <: WasmTarget.Dart2Wasm._TypeCheckers end

@testset "types.dart: the type values' helpers" begin
    local W = WasmTarget
    @test (D.TopTypeKind_object_kind(), D.TopTypeKind_dynamic_kind(), D.TopTypeKind_void_kind()) == (0, 1, 2)
    @test D.encoded_bool(true) == 1 && D.encoded_bool(false) == 0
    # a type admits null exactly when it admits nothing, Julia's null
    for T in (Any, Nothing, Union{Nothing,Int}, Int, Union{}, Union{Int,Float64}, Vector{Int}, Type)
        @test D.encoded_nullability(T) == (isa(nothing, T) ? 1 : 0)
    end
    # no class has a type parameter, so the environment indexes none
    local env = D.InterfaceTypeEnvironment()
    @test D._add(env, Vector{Int}) === nothing
    local e = try; D.lookup(env, TypeVar(:T)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal

    local t = D.Translator(W.check_subset(TypesCases.f_int32, (Int,), "types"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local types = D.Types(t)
    @test D.type_type(types) === Type && all(T -> T isa D.type_type(types), (Int, Union{Int,Nothing}, Vector, Union{}))
    # a type value's class is its kind, Julia's typeof
    for T in (Int, Union{Int,Float64}, Vector, Union{}, Type{Int}, Any)
        @test D.class_for_type(types, T) === typeof(T)
    end
    @test !D.is_specialized_class(types, Any) && !D.is_specialized_class(types, Function)
    @test D.top_type_kind(types, Any) == D.TopTypeKind_object_kind()
    @test D.normalize(types, Union{Nothing,Union{}}) === Nothing
    # a constant type has no free type variable: a static parameter left unbound is one
    local tv = TypeVar(:T)
    @test D.is_type_constant(types, Vector{Int}) && D.is_type_constant(types, Vector) && D.is_type_constant(types, Union{})
    @test !D.is_type_constant(types, Vector{tv}) && !D.is_type_constant(types, Base.unwrap_unionall(Vector))
    # the parts of dart's function and record types reject, Julia having neither
    for read in (() -> types.named_parameter_class_info[], () -> types.named_parameters_expected_type[],
                 () -> types.record_type_names_field_expected_type[], () -> D.named_parameter_type(types))
        local e2 = try; read(); nothing; catch x; x; end
        @test e2 isa W.RejectionError && e2.rejection isa W.Internal
    end
    # only the null case needs checking when every non-null operand value is of the tested type
    @test D._requires_only_null_assignability_check(types, Union{Nothing,Int}, Int)
    @test D._requires_only_null_assignability_check(types, Int, Integer)
    @test !D._requires_only_null_assignability_check(types, Any, Int)
    @test !D._requires_only_null_assignability_check(types, Union{Int,Float64}, Int)
end

@testset "types.dart: canUseTypeCheckHelper, against Julia's isa" begin
    local c = TypesCasesChecker()
    # a checker serves exactly the constant types whose values their class tells
    local values = Any[1, Int32(2), 1.5, "s", nothing, [1, 2], (1, 2.0), Int, Union{Int,Nothing}, Vector, Union{}, :x, 'c']
    local served = (Int, Integer, Union{Int,Nothing}, Nothing, Any, AbstractVector{<:Integer}, Tuple{Int,Float64},
                    Tuple{Any,Any}, DataType, Type, Union{DataType,Int}, Union{})
    for T in served
        @test D.can_use_type_check_helper(c, T, Any) == (T, false)
        # the class alone answers: a value is a T exactly when its class is under T
        @test all(x -> isa(x, T) == (typeof(x) <: T), values)
    end
    # a type that splits a kind's instances needs the value, and a type with a free variable is no
    # constant: neither has a checker
    local tv = TypeVar(:T)
    for T in (Type{Int}, Type{<:Integer}, Union{Type{Int},Int}, Vector{tv})
        @test D.can_use_type_check_helper(c, T, Any) == (nothing, false)
    end
    @test any(x -> isa(x, Type{Int}) != (typeof(x) <: Type{Int}), values)
    @test D._has_only_default_type_arguments(c, Vector{Int}) && D._get_type_with_defaults_to_bounds(c, Vector{Int}) === Vector{Int}
    @test !D._static_types_ensure_type_arguments_match(c, Vector{Int}, AbstractVector{Int})
end

@testset "types.dart: the type parameter offsets of nested binders" begin
    local W = WasmTarget
    local t = D.Translator(W.check_subset(TypesCases.f_int32, (Int,), "types"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local types = D.Types(t)
    # T's binder holds S's, which refers to T: T's range starts above S's
    local A = Tuple{T, Vector{S}} where S where T
    @test D.compute_function_type_parameter_offset(types, A) == 1
    @test D.get_function_type_parameter_index(types, A.var) == 1 && D.get_function_type_parameter_index(types, A.body.var) == 0
    @test D.compute_function_type_parameter_offset(types, A) == 1   # cached
    # a nested binder that does not refer to the outer parameter leaves the outer range at 0
    local B = Tuple{Vector{S} where S, T} where T
    @test D.compute_function_type_parameter_offset(types, B) == 0
    @test D.compute_function_type_parameter_offset(types, Vector) == 0
    local e = try; D.get_function_type_parameter_index(types, TypeVar(:U)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
end

@testset "types.dart: RuntimeTypeInformation's ranges and substitutions" begin
    local W = WasmTarget
    local t = D.Translator(W.check_subset(TypesCases.f_int32, (Int,), "types"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local rtt = D.RuntimeTypeInformation(Val(:_), t)
    @test D.RuntimeTypeInformation_no_substitution_index() == 0
    # consecutive class ids with one value join into a range, in id order
    local m = W.LinkedHashMap{Int,W.LinkedHashMap{Int,Int}}()
    local subs = W.LinkedHashMap{Int,Int}()
    for (k, v) in ((6, 1), (1, 0), (3, 1), (2, 0), (5, 1))
        subs[k] = v
    end
    m[5] = subs
    local r = D._build_ranges(rtt, m)
    @test [((x[1].start, x[1].end_), x[2]) for x in r[5]] == [((1, 2), 0), ((3, 3), 1), ((5, 6), 1)]
    # unrelated classes, or a superclass that takes no arguments, substitute nothing
    @test D._is_identity_substitution(rtt, nothing)
    @test D._is_identity_substitution(rtt, Union{Type,TypeVar}[])
    @test !D._is_identity_substitution(rtt, Union{Type,TypeVar}[Int])
end

@testset "types.dart: an instance constant's type is its class" begin
    local W = WasmTarget
    @test D.interface_type(W.InstanceConstant(Core.Const(1 // 2))) === Rational{Int}
end

module RttCases
abstract type S end
struct A <: S; x::Int; end
struct B <: S; y::Float64; end
f(n::Int) = n > 0 ? A(n) : B(1.0)
end

@testset "types.dart: RuntimeTypeInformation's tables over a closed world, against Julia's <:" begin
    local W = WasmTarget
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(W.check_subset(RttCases.f, (Int,), "types"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local rtt = t.types[].rtt[]
    local ids = t.class_id_numbering[].class_ids
    local super_to_sub = rtt._substitution_superclass_to_subclass[]
    local val(c) = c.c.val
    local table = [val(e) for e in val(rtt.type_row_displacement_table[]).entries]
    local offsets = [val(e) for e in val(rtt.type_row_displacement_offsets[]).entries]
    for (s, sid) in ids, (c, cid) in ids
        (s === Any || Base.has_free_typevars(s) || Base.has_free_typevars(c)) && continue
        # a rule exactly where Julia says the class is a proper subtype of the superclass
        local has_rule = haskey(super_to_sub, sid) && haskey(super_to_sub[sid], cid)
        @test has_rule == (c !== s && c <: s)
        # and the displaced row finds it: the superclass's offset plus the class id holds the superclass
        has_rule && @test table[offsets[sid + 1] + cid + 1] == sid
    end
    # every substitution is the identity: a Julia class's parameters are bound
    @test all(m -> all(==(D.RuntimeTypeInformation_no_substitution_index()), values(m)), values(super_to_sub))
    @test !D.requires_type_argument_substitution(rtt, RttCases.S)
    local names = [val(e) for e in val(rtt.type_names[]).entries]
    @test names[ids[RttCases.A] + 1] == string(RttCases.A) && names[1] == ""
end
