# The closed world's classes (dev/MARCH.md 1.C): every type a value of the program can have, in the
# order the program first meets it, with every type on its supertype chain. dart numbers the classes
# of its component, each library's classes in order (class_info.dart:864, `for (final library in
# translator.component.libraries) for (final cls in library.classes)`); a Julia program is the
# closed world Julia inferred, read once as the NIR, so its classes are the types the NIR carries.
# Julia answers every edge (ledger D3): a class's parent is its `supertype`, never re-derived.

# Julia's kinds, the concrete types of a type as a value, read from Base.iskindtype over Core's
# bindings (src/julia/construction.jl, core_kinds), never a copy of its list (D3, D5)
@quarantine unpinned "a type is a value in Julia, its class one of Julia's kinds, which Base.iskindtype names" Core.DataType const _KINDS = core_kinds()::Tuple{Vararg{DataType}}

# Whether a value's class tells whether it is of the type `T`: each kind wholly in `T` or wholly out of
# it. Julia's isa tests a type value against a type that splits its kind (Type{Int} holds Int and no
# other DataType) by the value itself, any other value by its class (julia/src/subtype.c:2511 jl_isa:
# `jl_is_type_type(t)`, then `jl_subtype(jl_typeof(x), t)`)
@quarantine pin"julia/src/subtype.c:2511 jl_isa" "julia/src/subtype.c:2511 jl_isa tests a type value by itself where the type splits its kind, any other value by its class (jl_typeof)" Base.typeintersect told_by_class(@nospecialize(T::Type))::Bool =
    all(k -> k <: T || typeintersect(k, T) === Union{}, _KINDS)

# a record of a fixed arity's (TupleRecord{N}, or Tuple{} for the empty shape), one arm of RecordArity
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses" "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses keys each record class by its RecordShape, its positional count here" Core.Int struct FixedArity
    n::Int
end
@quarantine pin"julia/src/builtins.c:946 jl_f_tuple" "julia/src/builtins.c:946 jl_f_tuple builds a tuple of the arity its argument count gives at run time" Core.DataType struct RunTimeArity end

"""
    RecordArity

A record class's arity: `FixedArity(n)`, the shape dart's record_class_generator.dart keys each record
class by (`TupleRecord{N}`, or `Tuple{}` for the empty shape), or `RunTimeArity()`, the array class's
(`TupleRecordArray`), whose arity Julia's jl_f_tuple fixes only at run time. Closed by its type: a
`@closed` `Union` of two concrete structs that subtype nothing, so no module adds a kind without
editing this line. The rest is a check, not construction: each `@exhaustive` match over it is checked
against its kinds when written and again at load (`check_closed`); a consumer may still test one kind
with `isa` (`record_arities`).

precedent(rust: enum + exhaustive match; dart: sealed class + exhaustive switch). Julia's differs: a
`Union` of concrete structs where Rust declares an enum and dart a sealed hierarchy, and its
exhaustiveness checked when the package loads, since Julia checks no match at compile time.
"""
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses" "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses keys its classes by RecordShape, a closed set of shapes; a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const RecordArity = Union{FixedArity, RunTimeArity}

"""
    record_member_tests(translator, T, field_checked) -> Union{Nothing,Vector{Tuple{Int,DataType,DataType}}}

The records an is check against `T` tests inline, field by field (types.jl IsCheckerCodeGenerator.generate):
for each tuple member of `T` and each record class of an arity the member admits, the class's id, the
class, and the member's shape at that arity (`typeintersect(member, NTuple{n,Any})`, Julia's tuple
subtyping covariant), each field of which its own is checker tests. `nothing` where a member is no
product of its fields' tests: a shape whose fields constrain one another (`Tuple{T,T} where T`), or a
field whose type no checker helper decides (`field_checked`, types.jl's canUseTypeCheckHelper). Such a check takes dart's general arm (types.dart:434
emitIsTest, makeType and the runtime's _isSubtype), as dart's every record type does. The one reading of
both: canUseTypeCheckHelper refuses the helper by it, and the is checker emits what it lists.
"""
@quarantine pin"julia/src/subtype.c:1348 subtype_tuple" "julia/src/subtype.c:1348 subtype_tuple: a tuple type's subtypes are those of its arity whose every field is a subtype of the type's, so a member is a product of its fields' tests where its shape at the arity is a DataType" Base.typeintersect function record_member_tests(translator, @nospecialize(T::Type), field_checked)::Union{Nothing,Vector{Tuple{Int,DataType,DataType}}}
    local out = Tuple{Int,DataType,DataType}[]
    local arities = translator.class_id_numbering[].covered_arities
    for t in Base.uniontypes(T)
        t <: Tuple || continue
        for (id, c) in zip(concrete_class_ids(translator, Tuple), concrete_classes(translator, Tuple))
            local r = tuple_record_arity(c)
            r === nothing && reject!(Internal("src/julia/classes.jl record_member_tests: class $c below Tuple is no record"), "record_member_tests")
            @exhaustive r::RecordArity begin
                (f::FixedArity) => begin
                    local n = f.n
                    local shape = typeintersect(t, NTuple{n,Any})
                    shape === Union{} && continue
                    shape isa DataType || return nothing
                    for k in 1:n
                        field_checked(fieldtype(shape, k)) || return nothing
                    end
                    push!(out, (id, c, shape))
                end
                # the array class where the member admits an arity no record covers (open_tuple_holds): the
                # member itself, its fixed positions and a Vararg tail's element each by its own test, after
                # the length test (julia/src/subtype.c:1348 subtype_tuple: the length first, then each field)
                RunTimeArity => begin
                    open_tuple_holds(t, c, arities) || continue
                    t isa DataType || return nothing
                    for p in t.parameters
                        field_checked(Base.unwrapva(p)) || return nothing
                    end
                    push!(out, (id, c, t))
                end
            end
        end
    end
    return out
end

"""
    constant_unmade(translator, cls) -> Union{Rejection,Nothing}

Why no constant of the class `cls` can be made, as constants.jl's visitInstanceConstant refuses it, or
`nothing` where one is made: a builtin type's value is its builtin constant; one held in an integer
register is its register's literal (register_constant_class: `Core.AddrSpace`, an enum), boxed
by its class's struct where a reference holds it; any other primitive type but a 128-bit integer (its
class's two halves) has no wasm representation and is Unquarantined; a class with no class info, outside
the closed world, is Internal (a register class's too: its box is its class's). The one source of the
fact: visitInstanceConstant rejects with it, and type_value_unmade reads it.
"""
@quarantine pin"dart2wasm/lib/constants.dart:908 ConstantCreator.visitInstanceConstant" "dart2wasm/lib/constants.dart:908 ConstantCreator.visitInstanceConstant makes an instance constant of its class's info; a Julia primitive type with no builtin type and no integer register has none but a 128-bit integer's" Base.isprimitivetype function constant_unmade(translator, cls::DataType)::Union{Rejection,Nothing}
    haskey(translator.builtin_types[], cls) && return nothing
    isprimitivetype(cls) && !type_expand_integer(cls) && !managed_pointer(cls) && !register_constant_class(translator, cls) &&
        return Unquarantined("src/constants.jl visitInstanceConstant: a constant of the primitive type $cls, with no wasm representation")
    haskey(translator.class_info, cls) ||
        return Internal("dart2wasm/lib/constants.dart:908 ConstantCreator.visitInstanceConstant: the class $cls of the constant has no class info")
    return nothing
end

"""
    type_value_unmade(translator, T) -> Union{Nothing,Some}

The parameter that keeps the type `T` from being a constant (`Some(p)`), or `nothing` where constants.jl
makes it: a parameter that is a value of a primitive type whose constant is not made (GenericMemory's
`Core.AddrSpace{Core}`), or a value of no class of the closed world (a `Vararg`'s Core.TypeofVararg),
each of which visitInstanceConstant rejects, found in `T`'s parameters and in theirs: a parameter value is
unmade exactly where constant_unmade rejects its class, the one source of which constants are made.
"""
@quarantine pin"julia/src/julia.h:971 jl_to_typeof" "julia/src/julia.h:971 jl_to_typeof reads every tag's type from its table; a type value whose parameter is a primitive whose constant is not made, or a value of no class, has no constant (src/julia/classes.jl constant_unmade)" Core.typeof function type_value_unmade(translator, @nospecialize(T))::Union{Nothing,Some}
    local walk(@nospecialize(x)) = begin
        if x isa Union
            local a = walk(x.a)
            return a === nothing ? walk(x.b) : a
        elseif x isa DataType
            for p in x.parameters
                local r = walk(p)
                r === nothing || return r
            end
            return nothing
        elseif x isa Type || x isa TypeVar || x isa Symbol
            return nothing
        end
        # any other value is an instance constant of its class, made where constant_unmade (the one source)
        # finds no rejection: a Vararg parameter's Core.TypeofVararg is of no class of the closed world
        return constant_unmade(translator, typeof(x)) === nothing ? nothing : Some(x)
    end
    return walk(T)
end

"""
    apply_type_cache(translator, operands, at) -> Vector{Pair{Vector{Any},Any}}

The cases of one apply_type statement, split as Julia's inliner splits a call over its arguments' unions
(Compiler/src/ssair/inlining.jl:526 ir_inline_unionsplit!): each entry a case, its signature one value
of each operand (a key), its result the constant Julia folds for it (a ConstantCase), tested in order
(src/intrinsics.jl, the run_time_type arm). An operand is a literal (`Some` of its value) or the type
Julia inferred for it, whose every member must have one value, a type (Julia's isconstType,
Compiler/src/typeutils.jl:9), so the operand's values are the members', and the keys are the split of
the operands' unions (typeutils.jl:261 switchtupleunion), under the bound inference splits within
(Compiler/src/abstractinterpretation.jl:352 is_union_split_eligible, `unionsplitcost <=
max_union_splitting`): every key the statement can meet at run time is a case's, so the split is fully
covered. Each entry's type is Julia's own fold of the call (Compiler/src/tfuncs.jl:1753 apply_type_tfunc,
a Const where every operand is one and the call cannot raise), a type value that has a constant
(type_value_unmade) and that a run-time type test decides (run_time_type_gap), so every answer is one of
WasmTarget's canonical constants and `===` on it stays the ref.eq of the identical arm. An operand of any
other type, operands whose split passes the bound, a key whose fold is Union{} (the call raises, Julia's
TypeError) or no Const (apply_type_tfunc answers a wider type), or an entry with no constant rejects at
the statement, located.

Julia's run time answers the call another way (julia/src/builtins.c:1547 jl_f_apply_type): a Union head
makes its union by jl_type_union (:1569), and any other head finds its type in its typename's cache
(julia/src/jltypes.c:1112 lookup_type), the hashed set lookup_type_set for a key typekey_hash can hash
(:1787), its linear cache (lookup_type_idx_linear, :1078) only for one it cannot, a key with a Union
parameter (type_hash, :1742). apply_type_tfunc itself splits no Union head:
it answers it at tfuncs.jl:1771, before its own split at :1812. WasmTarget holds every type value as one
constant (constants.jl _lowerTypeToConstant), so the run-time half finds the type among the statement's
cases rather than making it or looking it up in a typename's cache.

formal(dev/formal/TypeCacheLookup.tla): every key the operands can hold finds an entry, the one of its own key
"""
@quarantine pin"julia/Compiler/src/ssair/inlining.jl:526 ir_inline_unionsplit!" "Julia's run time makes a Union by jl_type_union and finds any other type in its typename's cache (jltypes.c:1112 lookup_type, hashed by lookup_type_set where typekey_hash can hash the key); WasmTarget holds every type value as one constant (constants.jl _lowerTypeToConstant), so the statement is split at compile time as the inliner splits a call, one constant case per key every value Julia's inference lets each operand hold, its type Julia's own fold, and the run-time half tests the cases in order" Core.Compiler.apply_type_tfunc function apply_type_cache(translator, operands::Vector{Any}, at::String)::Vector{Pair{Vector{Any},Any}}
    local argtypes = Any[op isa Some ? Core.Const(something(op)) : op for op in operands]
    for op in operands
        op isa Some || all(Core.Compiler.isconstType, Base.uniontypes(op)) ||
            reject!(Unquarantined("src/julia/classes.jl apply_type_cache: an operand of Julia's apply_type typed $op, whose values are no types of one value each, which the cache made at compile time cannot key"), at)
    end
    # inference splits only within its bound (abstractinterpretation.jl:352 is_union_split_eligible);
    # past it Julia makes no case per split
    local cost = Core.Compiler.unionsplitcost(Core.Compiler.fallback_lattice, argtypes)
    local bound = Core.Compiler.InferenceParams().max_union_splitting
    cost <= bound ||
        reject!(Unquarantined("src/julia/classes.jl apply_type_cache: Julia's apply_type on operands typed $(join(operands, ", ")), whose union split costs $cost, past inference's bound $bound (max_union_splitting)"), at)
    local entries = Pair{Vector{Any},Any}[]
    # each key one split of the operands' unions (switchtupleunion), a case of the inliner's union split
    for split in Core.Compiler.switchtupleunion(Core.Compiler.fallback_lattice, argtypes)
        local k = Any[a isa Core.Const ? a.val : a.parameters[1] for a in split]
        local folded = Core.Compiler.apply_type_tfunc(Core.Compiler.fallback_lattice, Any[Core.Const(v) for v in k])
        folded === Union{} &&
            reject!(Unquarantined("src/julia/classes.jl apply_type_cache: Julia's apply_type on $(join(k, ", ")), which apply_type_tfunc answers Union{}: the call raises, Julia's TypeError, which the cache does not port"), at)
        folded isa Core.Const ||
            reject!(Unquarantined("src/julia/classes.jl apply_type_cache: Julia's apply_type on $(join(k, ", ")), for which apply_type_tfunc gives no Const, only $folded"), at)
        local r = folded.val
        local why = type_value_unmade(translator, r)
        why === nothing ||
            reject!(Unquarantined("src/julia/classes.jl type_value_unmade: Julia's apply_type answering $r, whose type value has no constant ($(something(why)))"), at)
        local gap = r isa Type ? run_time_type_gap(r) : nothing
        gap === nothing || reject!(gap, "$at: Julia's apply_type answering $r")
        push!(entries, k => r)
    end
    return entries
end

"""
    applicable_cache(translator, operands, at) -> Vector{Pair{Vector{Any},Bool}}

The cases of one `applicable(f, args...)` statement, split as Julia's inliner splits a call over its
arguments' unions (Compiler/src/ssair/inlining.jl:526 ir_inline_unionsplit!), the split
apply_type_cache makes: each entry a case, its key one member of each operand (a type, the operand's
`isa` test), its answer Julia's run time's for every value of that key. An operand is a literal or
constant (`Some` of its value) or the type Julia inferred for it, each of whose members is a type of
one value (`Type{X}`, Julia's isconstType, Compiler/src/typeutils.jl:9) or a concrete class that is no
kind, so the run time's lookup key is the same for every value of the member; the keys are the split of
the operands' unions (typeutils.jl:261 switchtupleunion), every key the statement can meet at run time,
so the split is fully covered. Unlike apply_type_cache it splits past inference's bound
(max_union_splitting, abstractinterpretation.jl:352): there Julia's inference stops making a case per
split of the call (abstract_applicable answers Bool), but its run time still answers every key by its
lookup, and the keys are finite, the product of the operands' unions, so every key keeps its case (a
statement of three two-member operands, 8 keys past the bound of 4, answers as native).

Julia's run time answers the call by its method table (julia/src/builtins.c:1599 jl_f_applicable):
jl_method_lookup (julia/src/gf.c:3092) looks up the argument tuple type arg_type_tuple makes
(julia/src/jltypes.c:2477 jl_inst_arg_tuple_type: a type value `X` as `Type{X}`, any other value as its
type) with jl_mt_assoc_by_type, true where it finds a method. The answer depends on that tuple type
alone, so each case's answer is that lookup's on its key's tuple type, made at compile time by the run
time's own jl_method_lookup_by_tt (gf.c:3075) at the program's world. A member of any other type (an
abstract type, a kind whose values the lookup keys apart, `Type{T}` of more than one value) or a type
value with no constant (type_value_unmade) rejects at the statement, located.

formal(dev/formal/TypeCacheLookup.tla): every key the operands can hold finds an entry, the one of its own key
"""
@quarantine pin"julia/src/builtins.c:1599 jl_f_applicable" "Julia's run time answers applicable by a method table lookup on the arguments' tuple type (gf.c:3092 jl_method_lookup); WasmGC has no method table at run time, so the statement is split at compile time as the inliner splits a call, one case per key every value Julia's inference lets each operand hold, its answer the run time's own lookup on the key's tuple type (gf.c:3075 jl_method_lookup_by_tt), and the run-time half tests the cases in order; past inference's split bound too, as the run time answers every key, whose number is the product of the operands' unions" Core.Compiler.switchtupleunion function applicable_cache(translator, operands::Vector{Any}, at::String)::Vector{Pair{Vector{Any},Bool}}
    local keyable(@nospecialize(m)) = Core.Compiler.isconstType(m) || m isa DataType && isconcretetype(m) && !Base.iskindtype(m)
    for op in operands
        op === Union{} &&
            reject!(Unquarantined("src/julia/classes.jl applicable_cache: an operand of Julia's applicable typed Union{}, a value no run time holds, whose key no tuple type has"), at)
        op isa Some || all(keyable, Base.uniontypes(op)) ||
            reject!(Unquarantined("src/julia/classes.jl applicable_cache: an operand of Julia's applicable typed $op, whose members are no concrete classes or types of one value each, which the run time's lookup keys by value"), at)
        local unmade = op isa Some ? nothing :
            findfirst(m -> Core.Compiler.isconstType(m) && type_value_unmade(translator, m.parameters[1]) !== nothing, Base.uniontypes(op))
        unmade === nothing ||
            reject!(Unquarantined("src/julia/classes.jl type_value_unmade: an operand of Julia's applicable typed $op, whose type value $(Base.uniontypes(op)[unmade].parameters[1]) has no constant"), at)
    end
    local argtypes = Any[op isa Some ? Core.Const(something(op)) : op for op in operands]
    local entries = Pair{Vector{Any},Bool}[]
    # each key one split of the operands' unions (switchtupleunion), a case of the inliner's union split
    for split in Core.Compiler.switchtupleunion(Core.Compiler.fallback_lattice, argtypes)
        local k = Any[a isa Core.Const ? Core.Typeof(a.val) : a for a in split]
        # jl_inst_arg_tuple_type's tuple type of the key, and jl_mt_assoc_by_type's lookup of it
        local found = ccall(:jl_method_lookup_by_tt, Any, (Any, Csize_t, Any), Tuple{k...}, translator.component.world, nothing)
        push!(entries, k => found !== nothing)
    end
    return entries
end

"""
    types_equal_identity_premise(X) -> Bool

Whether every DataType equal to `X` is `X` itself, so Julia's jl_types_equal of `X` and another DataType answers by
identity (julia/src/subtype.c:436 obviously_unequal): `X` a DataType, neither TypeofBottom nor its supertype
Type{Union{}} (:438-441, equal though distinct), and either a concrete non-tuple DataType, which
jl_type_equality_is_identity (julia/src/jltypes.c:1354) answers by identity against every concrete type (every
DataType of its name with no free variable concrete, jltypes.c:1841 jl_precompute_memoized_dt), or a DataType of no
parameter, the one DataType of its name (subtype.c:458). Among DataTypes of no free variable: the run-time type
test's link-time check excludes the others (src/julia/runtime/rtutils.jl check_run_time_type_values). The one
reading of the premise: the compile-time cache's (types_equal_cache) and the run-time port's, through the closed
world's table by class id (src/julia/runtime/jltypes.jl jl_types_equal, jl_type_identity_premise).
"""
@quarantine pin"julia/src/subtype.c:436 obviously_unequal" "Julia answers two types' equality by identity where obviously_unequal decides it, a concrete non-tuple DataType or one of no parameter" Core.DataType types_equal_identity_premise(@nospecialize(X))::Bool =
    X isa DataType && X !== Core.TypeofBottom && X !== Core.TypeofBottom.super &&
        (isconcretetype(X) && X.name !== Tuple.name || isempty(X.parameters) && X.name.wrapper === X)

"""
    types_equal_cache(translator, operands, at) -> Union{Nothing,Vector{Pair{Vector{Any},Bool}}}

The cases of one foreign call of libjulia's `jl_types_equal(T, S)`, Base's `==` of two types
(julia/base/operators.jl:295), split as applicable_cache splits applicable's: each entry a case, its key
one member of each operand, its answer Julia's for every value of that key, tested in order (src/
intrinsics.jl, the types_equal arm). An operand is a literal or constant type (`Some` of it, its key
`Type{X}`) or the type Julia inferred for it, each of whose members is `Type{X}` or `DataType` itself. A
`Type{X}` holds every type equal to X (Julia's isa of a Type{X} is jl_types_equal, julia/src/subtype.c:2523),
one value only where X has a unique representation (Julia's isconstType, Compiler/src/typeutils.jl:9
hasuniquerep): such a member is told at run time by ref.eq with X's constant; any other is admitted only as
its operand's one member, whose values the run time never tests. Two `Type{X}` members make a key answered
by Julia's own jl_types_equal of the two X at compile time, which is every value's answer, jl_types_equal
being an equivalence (mutual subtyping). A `DataType` member, whose values no split
can key, is answered against the other operand's member `Type{X}` by two entries, in this order: the
key of X itself (Julia's answer, true), then the remainder, the `DataType` key, false. The remainder is
exact only where every DataType equal to X is X itself (types_equal_identity_premise). The free variables
are the program's type values' check, the run-time type test's (src/julia/runtime/rtutils.jl
check_run_time_type_values, registered by run_time_type_test!). Where no key splits the operands (a member
of any other type, such as an operand typed `Type`; two `DataType` operands; an X of no identity premise
against `DataType`) the answer is `nothing`: the run-time port answers (src/julia/runtime/rtutils.jl
jl_types_equal). An operand typed Union{}, a `Type{X}` of no unique representation beside another member,
or a type value the run-time tests compare with that has no constant (type_value_unmade) rejects at the
statement, located.

dart's counterpart is `_Type.operator ==` of each runtime type kind (sdk/lib/_internal/wasm/common/
type.dart:317 `_InterfaceType.operator ==`): structural, the class ids and the type arguments. Julia's
differs: its type equality is mutual subtyping, so two distinct types can be equal, and its runtime
answers by its subtyping algorithm, which WasmTarget does not port; WasmTarget holds every type value as
one constant (constants.jl _lowerTypeToConstant), so the statement is split at compile time.

formal(dev/formal/TypesEqualSplit.tla): every pair the operands can hold finds an entry, the first answering Julia's jl_types_equal
"""
@quarantine pin"julia/src/subtype.c:2353 jl_types_equal" "Julia's runtime answers type equality by mutual subtyping (subtype.c:2353 jl_types_equal), which WasmGC has no runtime for; dart's _Type.operator == (sdk/lib/_internal/wasm/common/type.dart:317) is structural, which Julia's is not; WasmTarget holds every type value as one constant (constants.jl _lowerTypeToConstant), so the statement is split at compile time as applicable's is, one case per key every value Julia's inference lets each operand hold, its answer the run time's own jl_types_equal, and an operand typed DataType keyed by its remainder where obviously_unequal answers by identity (subtype.c:436)" Core.Compiler.isconstType function types_equal_cache(translator, operands::Vector{Any}, at::String)::Union{Nothing,Vector{Pair{Vector{Any},Bool}}}
    length(operands) == 2 ||
        reject!(Internal("src/julia/classes.jl types_equal_cache: jl_types_equal of $(length(operands)) operands, not two (julia/src/julia.h:1903)"), at)
    local members = Vector{Any}[]
    for op in operands
        op === Union{} &&
            reject!(Unquarantined("src/julia/classes.jl types_equal_cache: an operand of jl_types_equal typed Union{}, a value no run time holds"), at)
        if op isa Some
            something(op) isa Type ||
                reject!(Unquarantined("src/julia/classes.jl types_equal_cache: jl_types_equal of $(repr(something(op))), no type, where Julia's == passes two (julia/base/operators.jl:295)"), at)
            push!(members, Any[Core.Typeof(something(op))])
        else
            local ms = Any[Base.uniontypes(op)...]
            # members no key splits (an operand typed Type, or Any): the run-time port answers (nothing)
            all(m -> m === DataType || Base.isType(m) && !(m.parameters[1] isa TypeVar), ms) || return nothing
            # a Type{X} of no unique representation holds every type equal to X, which no ref.eq tells
            # apart from another member's values: only as the operand's one member, never tested
            length(ms) == 1 || all(m -> m === DataType || Core.Compiler.isconstType(m), ms) ||
                reject!(Unquarantined("src/julia/classes.jl types_equal_cache: an operand of jl_types_equal typed $op, a member of which holds every type equal to its parameter (no unique representation, Compiler/src/typeutils.jl:12 hasuniquerep), which no ref.eq with one constant tests at run time"), at)
            push!(members, ms)
        end
    end
    # two operands each holding any DataType: no key splits them, the run-time port answers (nothing)
    all(ms -> DataType in ms, members) && return nothing
    local answer(@nospecialize(X), @nospecialize(Y)) = ccall(:jl_types_equal, Cint, (Any, Any), X, Y) != 0
    local entries = Pair{Vector{Any},Bool}[]
    for m1 in members[1], m2 in members[2]
        if m1 !== DataType && m2 !== DataType
            push!(entries, Any[m1, m2] => answer(m1.parameters[1], m2.parameters[1]))
            continue
        end
        local narrow = m1 === DataType ? m2 : m1
        local X = narrow.parameters[1]
        # no identity premise for X: the run-time port answers, by the other operand's premise or its gap (nothing)
        types_equal_identity_premise(X) || return nothing
        # the remainder is exact only for DataTypes of no free variable: the program's type values' check
        run_time_type_test!(translator, at)
        push!(entries, Any[narrow, narrow] => answer(X, X))
        push!(entries, (m1 === DataType ? Any[DataType, narrow] : Any[narrow, DataType]) => false)
    end
    # the constants the run-time tests compare with: each Type{X} key of an operand of more than one key
    for j in 1:2
        local column = unique(k[j] for (k, _) in entries)
        length(column) > 1 || continue
        for m in column
            m === DataType && continue
            local why = type_value_unmade(translator, m.parameters[1])
            why === nothing ||
                reject!(Unquarantined("src/julia/classes.jl type_value_unmade: an operand of jl_types_equal typed $(operands[j]), whose type value $(m.parameters[1]) has no constant ($(something(why)))"), at)
        end
    end
    return entries
end

"""
    new_struct_classes(translator, tytype, at) -> Vector{DataType}

The classes an allocation of a class only run time knows may make (Julia's `new` whose type operand is
typed `tytype`, a union of `Type{C}`): each member's class, in the union's order. Julia's codegen
allocates such a `new` by its runtime, jl_new_structv (julia/src/codegen.cpp:6575, its jlnew_func),
which reads the struct's layout from the type value (julia/src/datatype.c:1627) and raises TypeError
where the value is no concrete DataType (:1630). A WasmGC struct.new names its type where it is
written, and WasmTarget holds every type value as one constant (constants.jl _lowerTypeToConstant), so
the allocation is split at compile time over the type values Julia's inference lets the operand hold, as
the inliner splits a call over its argument's union (Compiler/src/ssair/inlining.jl:526
ir_inline_unionsplit!), each case the type value's identity with one class's constant (the code
generator's visitConstructorInvocation). A member that is no Type{C} of a concrete class (a type only
run time knows, such as DataType: jl_new_structv's own test, then its layout, at run time), or a class
whose type value has no constant (type_value_unmade), rejects at the statement, located.

formal(dev/formal/TypeCacheLookup.tla): every class the operand can hold finds its case, the one-operand case of the lookup
"""
@quarantine pin"julia/src/datatype.c:1627 jl_new_structv" "Julia's codegen allocates a struct whose type is no constant by its runtime's jl_new_structv (julia/src/codegen.cpp:6575), which reads the layout from the type value at run time; a WasmGC struct.new names its type at compile time and WasmTarget holds every type value as one constant (constants.jl _lowerTypeToConstant), so the allocation is split over the classes Julia's inference lets the operand hold, as the inliner splits a call over a union (julia/Compiler/src/ssair/inlining.jl:526 ir_inline_unionsplit!)" Base.uniontypes function new_struct_classes(translator, @nospecialize(tytype), at::String)::Vector{DataType}
    local classes = DataType[]
    for m in Base.uniontypes(tytype)
        local C = m isa DataType && m <: Type && length(m.parameters) == 1 ? m.parameters[1] : nothing
        C isa DataType && isconcretetype(C) ||
            reject!(Unquarantined("src/julia: an allocation of a class given as $tytype, no concrete class"), at)
        local why = type_value_unmade(translator, C)
        why === nothing ||
            reject!(Unquarantined("src/julia/classes.jl type_value_unmade: an allocation of a class given as $tytype, whose class $C has no constant ($(something(why)))"), at)
        push!(classes, C)
    end
    return classes
end

"""
    is_interface_class_type(translator, T, check_only_null_assignability) -> Bool

Whether dart's emitIsTest and emitAsCheck take their interface arm for the tested type `T`: dart's
`testedAgainstType is InterfaceType && classForType(testedAgainstType) == interfaceTypeClass`, a
Julia DataType that is a class of the closed world, its runtime test the class table's. The table
relates classes, so it answers a test only where a value's class tells it (`told_by_class`); a type
that splits a kind's instances (Type{X}) is tested by the value itself, and so is an open tuple type, whose
values a tuple record holds whatever their elements: each takes the arm only where the null case alone is tested,
which reads no table.
"""
@quarantine pin"julia/src/subtype.c:2511 jl_isa" "julia/src/subtype.c:2511 jl_isa tests a type value by itself where the type splits its kind, any other value by its class (jl_typeof), the relation the class table holds" Base.haskey function is_interface_class_type(translator, @nospecialize(T::Type), check_only_null_assignability::Bool)::Bool
    T isa DataType || return false
    haskey(translator.class_info, T) || return false
    check_only_null_assignability && return true
    # an open tuple type's values are held in its arities' records (open_tuple_holds), whose class says nothing of
    # their elements, which decide (julia/src/subtype.c:1348 subtype_tuple): the class table, which relates classes,
    # never answers it; the record member tests or the runtime's subtype test do
    T <: Tuple && !isconcretetype(T) && return false
    return told_by_class(T)
end

"""
    closed_world_classes(world, at) -> Vector{DataType}

The classes of the closed world `world`, its NIR, in the order its walk first meets them: each body in
order, its argument types (its MethodInstance's signature), then each statement's type, then the
type of each literal and binding its statements read, an operand or a statement of its own (nir_value_type: the value's own
type, which no statement's type need hold: `"hello"` compared, a `const` Ref read), then its return
type. A type meets the walk by Julia's own inferred form: a `Union` by its members, a
`Vararg` by its element, a type as a value (`Type{X}`, or a `UnionAll` under `Type`) by its kind
(`typeof(X)`, or every kind when `X` is not known) and by the classes `X` denotes (`X` itself, or each
member of a Union, that is a DataType, one with a free type variable a class no value has), whose ids a
type value's layout holds (dart's `classIds[type.classNode]`, constants.dart:430
_makeInterfaceTypeConstant); any other `UnionAll` by the class representing its instances, their nearest common
superclass (unionall_class). A class
met brings its supertype chain to `Any`, the root, and a concrete class that is not a kind brings
its field types, each met as a value's type. `Union{}`, the type of no value, brings nothing. Where
the program holds a type value, every class's type value can be made (the typeof table), so each
class's parameters that are types or type variables are met as constants, to the fixpoint.

precedent(dart: a component's classes, the libraries' classes in order, class_info.dart:864).
Julia's differs: a program declares no class list, so the list is the types Julia inferred for its
values, each met once, and a parametric instance (`Vector{Int64}`) is a class of its own, as Julia's
`supertype` gives it.

formal(dev/formal/ValueClasses.tla): every class a value can have listed once, closed under supertype and fields, nothing extra
formal(dev/formal/TypeParamClasses.tla): where a type value is held, every listed class's type parameters are listed, at any depth, nothing extra, the pass ends
"""
@quarantine pin"julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel" "a Julia program declares no class list; its classes are the types Julia inferred for its values over the closed world julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel infers for a trimmed program" Base.unwrap_unionall function closed_world_classes(world::NirWorld, at::String)::Vector{DataType}
    local out = DataType[]
    local seen = Base.IdSet{DataType}()
    local objs = Set{NirConst}()
    for b in world
        foreach(t -> _meet_value!(out, seen, t, at), Base.unwrap_unionall(b.ci.def.specTypes).parameters)
        # a varargs method's body reads its trailing arguments as one tuple (NirVarargPacking); one packed
        # at entry whose class only run time knows is the record of its arity (jl_f_tuple's), as a call's is
        local va = nir_vararg_packing(b.ci.def)
        va === nothing || _meet_value!(out, seen, va.packed, at)
        va !== nothing && va.at_entry && !isconcretetype(va.packed) && _meet_tuple_record!(out, seen, va.packed, at)
        foreach(t -> _meet_value!(out, seen, t, at), b.types)
        for st in b.stmts
            for v in nir_value_operands(st)
                # a literal, or a constant binding's value, is a constant constants.jl instantiates:
                # its object graph (_meet_constant!)
                v isa NirConst && _meet_constant!(out, seen, objs, v.c.val, at)
                v isa NirGlobal && (_meet_value!(out, seen, nir_value_type(b, v), at);
                                    _meet_constant!(out, seen, objs, nir_binding_value(v.binding, at).c.val, at))
            end
            # a binding read as a statement of its own (Kernel's StaticGet) starts at its value, the
            # constant its lazy initializer instantiates (StaticFieldInitializerCodeGenerator): its
            # object graph, as an operand's; the statement's type is met with b.types. A binding with no value
            # has none: its initializer instantiates the binding's name and module, the UndefVarError it
            # raises (nir_binding_initializer, the one list)
            if st isa NirGlobalRead
                for c in nir_binding_initializer(st.binding, at)
                    _meet_constant!(out, seen, objs, c, at)
                end
            end
            # a tuple's class is its operands' (nir_tuple_type), which the statement's widened type
            # may hide; so is the tuple an invoke of a varargs specialization of an open count packs
            # (nir_vararg_call_tuple); one whose class only run time knows is the record of its arity
            if st isa NirCall && nir_callee(st) === Core.tuple
                local tt = nir_tuple_type(b, st)
                isconcretetype(tt) ? _meet_value!(out, seen, tt, at) : _meet_tuple_record!(out, seen, tt, at)
            end
            # a tuple whose length only run time knows, Core.tuple(v...) (julia/src/builtins.c:661
            # jl_f__apply_iterate then :946 jl_f_tuple): the record of its run-time arity where the world has
            # one, else the array class (src/intrinsics.jl's apply_iterate arm), or the empty tuple
            if st isa NirCall && nir_callee(st) === Core._apply_iterate && length(st.args) >= 3 && applies_tuple(st.args[3])
                _meet_value!(out, seen, TupleRecordArray, at)
                _meet_value!(out, seen, Tuple{}, at)
            end
            # throw_methoderror's arguments, the tuple jl_method_error makes of them (jl_f_tuple), passed
            # as the runtime's open Tuple: the record of their count
            st isa NirCall && nir_callee(st) === Core.throw_methoderror && _meet_value!(out, seen, tuple_record_class(length(st.args) - 2), at)
            # a DataType's field named at run time (src/code_generator.jl visitInstanceGet) reads its tables
            # (kind_field_table): `hash`, an Int32, and `flags`, a UInt16, each boxed into the read's open result
            if st isa NirCall && nir_callee(st) === Core.getfield && length(st.args) >= 3 && !(st.args[3] isa NirConst) &&
                    let rt = nir_value_type(b, st.args[2]); rt === DataType || Base.isType(rt) && rt.parameters[1] isa DataType end
                _meet_value!(out, seen, Int32, at)
                _meet_value!(out, seen, UInt16, at)
            end
            # a memory builtin on a reference whose type is no concrete GenericMemoryRef checks its
            # operand at run time (builtins.c:1781 jl_f_memoryrefget's JL_TYPECHK, the erased arm of
            # src/intrinsics.jl), raising TypeError with GenericMemoryRef, the type as a value
            st isa NirCall && length(st.args) >= 2 && nir_callee(st) isa Core.Builtin &&
                Dart2Wasm.generate_static_intrinsic(Val(:memory_erased_call), nir_callee(st), length(st.args) - 1, nir_value_type(b, st.args[2])) &&
                _meet_constant!(out, seen, objs, GenericMemoryRef, at)
            if st isa NirInvoke
                local vt = nir_vararg_call_tuple(b, st)
                vt !== nothing && (isconcretetype(vt) ? _meet_value!(out, seen, vt, at) : _meet_tuple_record!(out, seen, vt, at))
            end
        end
        _meet_value!(out, seen, b.ci.rettype, at)
    end
    # one pass over the list as it grows (dev/formal/TypeParamClasses.tla). Every tuple can reach a slot whose
    # static type is open, where it is the record of its arity (tuple_record_class, convertType's box): each
    # concrete tuple class brings its record. A class's type value holds its parameters (DataType's
    # `parameters`, _kind_instance_fields), and the table of every class's type value is read by Julia's
    # typeof (src/intrinsics.jl to_typeof) and by an as check's failure, which names the type it read back
    # from the class id (src/types.jl:607, src/julia/runtime/rtutils.jl jl_to_typeof); each reader's result
    # is a DataType, so where the table can be made the walk has met that kind. There, each class's
    # parameter is a constant of its type value's `parameters` svec whose object graph the walk meets
    # (_meet_constant!): a type, a type variable, or a value Julia stores in the svec (a bits value boxed,
    # julia/src/jltypes.c:2089 inst_datatype_inner, its `parameters` svec: GenericMemory's Core.AddrSpace{Core}(0x00), a Val's Int64; a
    # Symbol; a tuple of them), each of whose classes the type value's constant holds an instance of; a
    # Vararg (the abstract Tuple's parameter) is of no class, its type value unmade (type_value_unmade); and
    # each class it brings is passed over in turn, to the fixpoint
    local held = DataType in seen
    local k = 0
    while k < length(out)
        local c = out[k += 1]
        if held
            for p in c.parameters
                p isa Core.TypeofVararg || _meet_constant!(out, seen, objs, p, at)
            end
        end
        local r = boxed_record_class(c)
        r === nothing || _meet_value!(out, seen, r, at)
    end
    return out
end

# whether `v`, the function an _apply_iterate statement applies, is Julia's tuple builtin, a literal or a constant
# binding: jl_f__apply_iterate's `f == BUILTIN(tuple)` (julia/src/builtins.c:696), the one test of a splat into a tuple
@quarantine pin"julia/src/builtins.c:661 jl_f__apply_iterate" "julia/src/builtins.c:661 jl_f__apply_iterate applies its function to the arguments it gathers; the tuple builtin's application is the tuple of them (:946 jl_f_tuple)" Core.tuple applies_tuple(v::NirValue)::Bool =
    v isa NirConst ? v.c.val === Core.tuple : v isa NirGlobal && nir_binding_is_constant(v.binding) && v.binding.value === Core.tuple

# the record class a tuple of static type `T` takes where its class only run time knows: its arity's,
# a fixed one; a tuple of no fixed length brings none (the code generator rejects it where it meets it)
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses" "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses: its recordClasses holds one class per record shape, which a tuple of open elements takes" Base.unwrap_unionall function _meet_tuple_record!(out::Vector{DataType}, seen::Base.IdSet{DataType}, @nospecialize(T), at::String)::Nothing
    local tt = Base.unwrap_unionall(T)
    tt isa DataType && tt <: Tuple && !any(p -> p isa Core.TypeofVararg, tt.parameters) || return nothing
    _meet_value!(out, seen, tuple_record_class(length(tt.parameters)), at)
    return nothing
end

"""
    TupleRecord{N}

The class of a Julia tuple of `N` elements held where its static type is open (`Any`, `Tuple`,
`Tuple{Any,Any}`, a Union of tuple types): dart2wasm's record class of a shape, one class per shape
with a top-typed field per element (record_class_generator.dart:84 generateRecordClasses: its recordClasses, :280
_generateFields, its fields `Object? \$1..\$N`), here per arity `N ≥ 1`, a Julia tuple having
positional elements only, and one for the shape of an arity only run time knows, `N` the value
`RunTimeArity()` (`TupleRecordArray`); the empty shape's class is `Tuple{}` itself (`tuple_record_class`). A tuple whose static type is concrete is its own class, its fields unboxed;
convertType boxes it into its arity's record where it flows into an open slot and unboxes it where
Julia narrows it back (a PiNode, a typeassert), as dart boxes a value type on upcast. Julia's egal and
isa of a tuple read its fields (builtins.c:100 compare_fields; a tuple type is covariant), as dart's
record is-check reads its fields (_checkRecordType, type.dart:585 _RecordType._checkInstance). No Julia
value has the type: a struct of one field of type `Union{}`, uninhabited, its fields the record's
(`class_instance_fields`).

precedent(dart: the record classes of record_class_generator.dart, one per RecordShape). Julia's
differs: its tuple's type is its elements' (jl_f_tuple), so a tuple of a concrete static type keeps its
own class and only an open one is a record; the typeof of an open tuple, a type made at run time,
stays a rejection (A68S3).
"""
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:280 _RecordClassGenerator._generateFields" "pkg/dart2wasm/lib/record_class_generator.dart:280 _RecordClassGenerator._generateFields gives a record class a top-typed field per element, a tuple's record here" Core.Union struct TupleRecord{N}
    _never::Union{}
end

# the record class of a tuple of `n` elements (TupleRecord), the one name of it; the empty shape's is
# Tuple{} itself, the class of Julia's one empty tuple (julia/src/julia.h:1134 jl_emptytuple), which has
# no field to box, so the empty tuple is never boxed (and a class of no field of its own shares its
# superclass's struct, so its reference could not be told apart from that struct's other classes)
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses" "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses: its recordClasses maps each shape to its class, a tuple's arity to its record here" Core.Int tuple_record_class(n::Int)::DataType = n == 0 ? Tuple{} : TupleRecord{n}

# the record a value of the class `c` is boxed into where it is held at the top type (convertType's box, unboxed where
# Julia narrows it back): its arity's record where `c` is a concrete tuple class of at least one field; else nothing, a
# class that is no concrete tuple, or Tuple{}, the class of Julia's one empty tuple, which is its own record
# (tuple_record_class(0)): it has no field to box, so `fieldcount(c) > 0` is the arity-0 case, never boxed. The one
# statement of the boxing rule, read by the walk (each concrete tuple class brings its record), top_held_classes and
# convertType
@quarantine pin"pkg/dart2wasm/lib/translator.dart:1597 Translator.convertType" "pkg/dart2wasm/lib/translator.dart:1597 Translator.convertType boxes a value type where it flows into an open slot; a concrete tuple class is boxed into its arity's record" Core.Tuple boxed_record_class(@nospecialize(c))::Union{DataType,Nothing} =
    c isa DataType && c <: Tuple && isconcretetype(c) && fieldcount(c) > 0 ? tuple_record_class(fieldcount(c)) : nothing

"""
    TupleRecordArray

The class of a Julia tuple whose arity only run time knows and whose arity has no record class in the
closed world: Julia makes that tuple's type on its cache's miss (julia/src/builtins.c:946 jl_f_tuple,
jltypes.c:2477 jl_inst_arg_tuple_type), where the closed world holds one class built to hold any arity, its
one field the argument buffer, dart's `WasmArray<Object?>` of positional arguments (translator.dart:262
nullableObjectArrayTypeRef). The arity alone picks a tuple's class (`tuple_record_arity`), so each tuple
has one representation (dev/formal/TupleRecordSplat.tla OneRepresentation). It is the record class of that
shape, `TupleRecord{RunTimeArity()}`, uninhabited as every `TupleRecord` (no Julia value has the type): an
alias, since Julia 1.12 refuses a struct of no parameter with a field of type `Union{}` ("Tuple field type
cannot be Union{}", the layout it computes when the type is declared), where a parametric one's waits. Its
objectid is its contents' (an immutable's, builtins.c jl_object_id), as every record's.

precedent(julia: builtins.c:738 arg_heap, the buffer jl_f__apply_iterate fills; dart: translator.dart:262
nullableObjectArrayTypeRef; cpython: PyTupleObject, one object of any length). Julia's differs: it
allocates `jl_datatype_size(tt)` of a type it finds or makes; this keeps the buffer, whose type is never made.
"""
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses" "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses keys a record class by its shape; a shape of run-time arity is Julia's alone (julia/src/builtins.c:946 jl_f_tuple), its class the record of that shape" WasmTarget.TupleRecord const TupleRecordArray = TupleRecord{RunTimeArity()}

# the arity of the record class `c` (TupleRecord, Tuple{} for the empty shape, TupleRecordArray), or nothing for any other class
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses" "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses: its recordClasses keys each class by its shape, a record's arity its parameter here" Core.DataType tuple_record_arity(@nospecialize(c))::Union{RecordArity,Nothing} =
    c === Tuple{} ? FixedArity(0) : c === TupleRecordArray ? RunTimeArity() :
    c isa DataType && c <: TupleRecord && c.parameters[1] isa Int ? FixedArity(c.parameters[1]) : nothing

# the arities whose record class is among `classes` (the closed world's): Julia's tuple types its cache
# holds (jltypes.c:1133 lookup_typevalue), the one answer of which arities a record covers, computed once
# when the class ids are fixed (src/class_info.jl ClassIdNumbering.covered_arities), which every reader reads
@quarantine pin"julia/src/jltypes.c:1133 lookup_typevalue" "julia/src/jltypes.c:1133 lookup_typevalue finds a tuple type in its cache; the closed world's record classes are the arities it holds" Base.Set function record_arities(classes)::Set{Int}
    local out = Set{Int}()
    for c in classes
        local r = tuple_record_arity(c)
        r isa FixedArity && push!(out, r.n)
    end
    return out
end

# whether Julia's typeof of a value of the class `c` is a type no table entry holds: a tuple's record of
# N ≥ 1 elements or of an arity only run time knows (TupleRecordArray), whose values' type is the tuple
# type of their elements' types (jl_f_tuple's jl_inst_arg_tuple_type, jltypes.c:2477), known only at
# run time; the empty shape's class is Tuple{}, the type of Julia's one empty tuple, which its entry
# holds. The one source of which classes the typeof table holds no entry for and to_typeof answers by
# their own arms (src/intrinsics.jl, record_typeof)
@quarantine pin"julia/src/jltypes.c:2477 jl_inst_arg_tuple_type" "julia/src/jltypes.c:2477 jl_inst_arg_tuple_type: a tuple's type is the tuple type of its elements' types, which a record class's tag does not name but the empty tuple's, Tuple{}" Core.Tuple record_typeof_unmade(@nospecialize(c))::Bool =
    c !== Tuple{} && tuple_record_arity(c) !== nothing

# Julia's typeof of a value of the record class `c` (record_typeof_unmade) whose inferred type is `T`, known
# at compile time: the one tuple type `T` holds at the record's arity where `T` holds one (typeintersect with
# NTuple{N,Any} a concrete type, every tuple of it its type: jl_typeof of a leaf type's instance), as
# Union{Tuple{Int64},Tuple{Int64,Float64}} holds Tuple{Int64} at arity 1; else nothing, a type Julia's
# jl_f_tuple would find or make at run time (julia/src/builtins.c:946), which src/intrinsics.jl to_typeof
# raises for (formal(dev/formal/TupleRecordSplat.tla) TypeofAgrees); the array class's arity only run
# time knows, so no type of its pins one
@quarantine pin"julia/src/builtins.c:946 jl_f_tuple" "julia/src/builtins.c:946 jl_f_tuple: a tuple's type is the tuple type of its elements' types; where Julia's inferred type of the value holds one tuple type of its arity, that leaf type is every such tuple's" Base.typeintersect function record_typeof(@nospecialize(T), @nospecialize(c))::Union{DataType,Nothing}
    return @exhaustive something(tuple_record_arity(c))::RecordArity begin
        (f::FixedArity) => (local shape = typeintersect(T, NTuple{f.n,Any}); shape isa DataType && isconcretetype(shape) ? shape : nothing)
        RunTimeArity => nothing
    end
end

# the Julia-only row of the fatal gap where record_typeof pins no type (src/intrinsics.jl, the fatal arm, which reports
# it as Unquarantined's text at the statement's run-time location): the record class, the one text of it
@quarantine pin"julia/src/builtins.c:946 jl_f_tuple" "julia/src/builtins.c:946 jl_f_tuple makes a tuple's type at run time where its cache has none, a DataType WasmTarget never makes (audit A68S3)" Base.string record_typeof_message(@nospecialize(c))::String =
    string("julia/src/jltypes.c:2477 jl_inst_arg_tuple_type: typeof of a tuple held as ", c, ", whose type, the tuple type of its elements' types, is not made at run time (audit A68S3)")

# the table of each class's type value, by class id (translator.classes, the one map from an id to its class): the
# class where its type value is a constant, Julia's typeof of its values; nothing for the top, which no value carries,
# for a class whose type value has no constant (type_value_unmade) and for a tuple's record, whose values' type is
# their elements' (record_typeof_unmade). The one list of the type values typeof answers: src/intrinsics.jl to_typeof's
# table and the rows of its lookup of a tuple's type (tuple_type_rows) read it
@quarantine pin"julia/src/julia.h:971 jl_to_typeof" "julia/src/julia.h:971 jl_to_typeof reads a tag's type from the table of tags' types; WasmTarget's tag is the class id, its table each class's type value where a constant of it is made" Core.DataType type_value_entries(translator)::Vector{Union{Nothing,DataType}} =
    Union{Nothing,DataType}[info.cls === nothing || type_value_unmade(translator, info.cls) !== nothing || record_typeof_unmade(info.cls) ? nothing : info.cls for info in translator.classes[]]

# the closed world's tuple types of `n` elements among the table's entries (type_value_entries), in its order: the
# rows of typeof's lookup of a tuple held as its record (src/record_class_generator.jl _generateRecordRuntimeTypeHelper), Julia's cache of tuple
# types, which jl_lookup_arg_tuple_type searches by the arguments' types (julia/src/jltypes.c:2472, lookup_typevalue
# :1133). A row whose element no value's typeof is, a Type{X} (jl_typeof answers no Type{X}: (Int64,) is a
# Tuple{DataType}) or a type the table holds no entry of, is the type of no tuple of the world: left out, it is never
# matched, as no field's typeof could equal its element
@quarantine pin"julia/src/jltypes.c:1133 lookup_typevalue" "julia/src/jltypes.c:1133 lookup_typevalue finds a tuple type in its cache by its elements' types; the closed world's tuple types are the cache a program can hit" Core.Tuple function tuple_type_rows(entries::Vector{Union{Nothing,DataType}}, n::Int)::Vector{DataType}
    local held = Base.IdSet{DataType}(e for e in entries if e !== nothing)
    return DataType[e for e in entries if e !== nothing && e <: Tuple && isconcretetype(e) && fieldcount(e) == n &&
                    all(p -> p isa DataType && !Base.isType(p) && p in held, e.parameters)]
end

# whether the class `c` holds values of the open tuple type `T` (a Tuple type no concrete class is), in a
# closed world whose records cover `arities` (record_arities): the record classes of the arities `T`
# admits, a tuple of a concrete type boxed into its arity's record where it flows into an open slot
# (TupleRecord), never a concrete tuple class itself; and the array class (TupleRecordArray) where `T`
# admits an arity no record covers, a Vararg member always (dev/formal/TupleRecordSplat.tla IsaAgrees, its
# Broken variant HoldsOmitsArray); the one rule the class-id ranges (getConcreteClassIdRange) and the type
# rules (_buildTypeRules) read
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses" "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses: a value of a record type is an instance of the record class of its shape, a tuple's arity here" Base.typeintersect function open_tuple_holds(@nospecialize(T), @nospecialize(c), arities::Set{Int})::Bool
    local r = tuple_record_arity(c)
    r === nothing && return false
    return @exhaustive r::RecordArity begin
        (f::FixedArity) => typeintersect(T, NTuple{f.n,Any}) !== Union{}
        RunTimeArity => any(Base.uniontypes(T)) do m
            local t = Base.unwrap_unionall(m)
            t isa DataType && t <: Tuple && (Base.isvatuple(t) || !(fieldcount(t) in arities))
        end
    end
end

# A constant's object graph met by the walk (dev/formal/ValueClasses.tla's MeetObject): the value's
# class, then every value it holds that constants.jl instantiates in its place, a field's value, an
# svec's or a memory's element, a type value's own fields (its kind's layout, _kind_instance_fields), each
# object walked once, as the model's seenObj holds every object: a mutable one by its identity and an
# immutable one by Julia's ===, a literal's key (NirConst, its hash bounded), so a constant whose
# immutable fields share heap objects is walked in linear time, never once per path (a 40-level DAG
# has 2^40). A field declared abstract (Any) holds a value whose class only the value tells.
# precedent(dart: dart2wasm's record class collection walks each constant's children once, its cache
# a Set.identity of the constants met, record_class_generator.dart:773; kernel's
# VisitOnceConstantVisitor.visitConstant, visitor.dart:1546, the same rule). Julia's differs: a constant
# is no canonical node, so an immutable value is met by === (its NirConst key), a mutable one by identity.
@quarantine pin"pkg/dart2wasm/lib/record_class_generator.dart:773 _RecordVisitor.defaultConstantReference" "a constant's object graph is walked once per object, as dart2wasm's record class collection visits each constant's children once (pkg/dart2wasm/lib/record_class_generator.dart:773 _RecordVisitor.defaultConstantReference); a Julia constant is keyed by === where dart's canonical node is keyed by identity" Base.Set function _meet_constant!(out::Vector{DataType}, seen::Base.IdSet{DataType}, objs::Set{NirConst}, @nospecialize(v), at::String)::Nothing
    if !isbits(v)
        local key = NirConst(Core.Const(v))
        key in objs && return nothing
        push!(objs, key)
    end
    local t = typeof(v)
    _meet_value!(out, seen, Core.Typeof(v), at)
    if t === Core.SimpleVector
        foreach(x -> _meet_constant!(out, seen, objs, x, at), v)
    elseif t <: Core.GenericMemory
        # a memory's length and its elements, the values its data array holds (_memory_instance_fields;
        # Julia's `ptr`, a host address, is not one), each element written; a byte memory's data owner, a
        # constant's `nothing` (src/constants.jl)
        _meet_value!(out, seen, Int, at)
        foreach(k -> isassigned(v, k) && _meet_constant!(out, seen, objs, v[k], at), eachindex(v))
    elseif t <: Core.GenericMemoryRef
        # a reference's index and its memory (_memoryref_instance_fields; Julia's address is not one)
        _meet_value!(out, seen, Int, at)
        _meet_constant!(out, seen, objs, v.mem, at)
    elseif Base.iskindtype(t)
        for f in _kind_instance_fields(t, at)
            f.index > 0 && isdefined(v, f.index) && _meet_constant!(out, seen, objs, getfield(v, f.index), at)
        end
    elseif t === Core.TypeName
        # a TypeName's type caches are queued, never recursed into (julia/src/staticdata.c:863-867, "don't recurse
        # into several fields"), and pruned to the types reached otherwise (typename_cache_pruned): each cache is a
        # SimpleVector whose kept entries are type values the walk meets by their own reach, never by the cache
        for i in 1:fieldcount(t)
            isdefined(v, i) || continue
            fieldname(t, i) in TYPENAME_CACHES ? _meet_value!(out, seen, Core.SimpleVector, at) :
                _meet_constant!(out, seen, objs, getfield(v, i), at)
        end
    elseif !isprimitivetype(t)
        for i in 1:fieldcount(t)
            isdefined(v, i) && _meet_constant!(out, seen, objs, getfield(v, i), at)
        end
    end
    return nothing
end

# a value's type met by the walk, by Julia's inferred form
@quarantine pin"julia/base/runtime_internals.jl:924 isType" "a value's type is Julia's inferred form: a DataType, a Union of them, a Vararg's element, or a type as a value, Julia's isType, whose parameter names the classes the value denotes" Base.isType function _meet_value!(out::Vector{DataType}, seen::Base.IdSet{DataType}, @nospecialize(t), at::String)::Nothing
    t === Union{} && return nothing
    if t isa Union
        foreach(u -> _meet_value!(out, seen, u, at), Base.uniontypes(t))
    elseif t isa Core.TypeofVararg
        _meet_value!(out, seen, isdefined(t, :T) ? t.T : Any, at)
    elseif t isa UnionAll && t <: Type
        foreach(k -> _meet_class!(out, seen, k, at), _KINDS)
    elseif t isa UnionAll
        # a value of one of the UnionAll's instances, each a class of its own met where the value is made: the
        # class representing them all (unionall_class), as an abstract class's value meets that class
        _meet_class!(out, seen, unionall_class(t, at), at)
    elseif t isa DataType && Base.isType(t)
        local x = t.parameters[1]
        if x isa TypeVar
            foreach(k -> _meet_class!(out, seen, k, at), _KINDS)
        else
            _meet_class!(out, seen, typeof(x), at)
            # the classes the type value denotes, so its layout's classId has one (the kinds' fields,
            # below): a DataType, or each DataType member of a Union; one with a free type variable (a
            # UnionAll's body, `Array{T,1}`) denotes itself, a class no value has (class_is_abstract), as
            # DataType's own supertype `Type{T}` is
            for d in (x isa Union ? Base.uniontypes(x) : Any[x])
                d isa DataType && _meet_class!(out, seen, d, at)
            end
        end
    elseif t isa DataType
        _meet_class!(out, seen, t, at)
    else
        reject!(Internal("src/julia/classes.jl: a value's type $t, a $(typeof(t)), no form of Julia's inferred types"), at)
    end
    return nothing
end

"""
    unionall_class(U, at) -> DataType

The class representing a value of the UnionAll type `U` (one not under `Type`): Julia's instances of `U`
(`Vector{Int64}`, `Vector{Float64}` of `Vector`) are each a class of its own, so their one class is the nearest
on Julia's supertype chain of `U`'s body that holds `U` whole, the first with none of `U`'s free type variables
(`Vector`'s `Any`; `F{T} where T`'s supertype where it binds no `T`). The one answer of the walk
(_meet_value!) and of the translator's toMostSpecificInterfaceType, which also takes it for a Union whose
join is a UnionAll. A body that is no DataType (`Union{A{T},B{T}} where T`) rejects, located.

precedent(dart: dart2wasm/lib/translator.dart:940 Translator.toMostSpecificInterfaceType walks a type
parameter's type to its bound, an interface type whose class is its representation). Julia's differs: a
parametric type's instances are distinct classes, never one class with type arguments, so the walk is up
Julia's `supertype` chain to the first class every instance shares.

formal(dev/formal/UnionAllClass.tla): the class met has no free variable, holds every instance, and is their nearest common superclass; the walk ends
"""
@quarantine pin"pkg/dart2wasm/lib/translator.dart:940 Translator.toMostSpecificInterfaceType" "pkg/dart2wasm/lib/translator.dart:940 Translator.toMostSpecificInterfaceType walks a type parameter to its bound, an interface type, the class representing every value of the type; a Julia UnionAll's instances are each a class of their own, their nearest common superclass on Julia's supertype chain" Base.supertype function unionall_class(@nospecialize(U::UnionAll), at::String)::DataType
    local c = Base.unwrap_unionall(U)
    c isa DataType || reject!(Unquarantined("src/julia/classes.jl: the UnionAll type $U, whose body $c is no class"), at)
    # a class with a free variable of U's is no class a value has, and Julia's subtyping reads that variable
    # as any type (`Vector <: Array{T,1}` holds), so the free-variable test is what moves the walk on; the
    # first class free of them already holds U whole, the subtype test a guard of that claim
    # (dev/formal/UnionAllClass.tla: IsClass, HoldsAll, Nearest)
    while Base.has_free_typevars(c) || !(U <: c)
        c = supertype(c)
    end
    return c
end

# a class met by the walk: itself, its supertype chain, and a concrete non-kind class's field types
@quarantine pin"pkg/dart2wasm/lib/class_info.dart:420 ClassInfoCollector._createStructForClass" "pkg/dart2wasm/lib/class_info.dart:420 ClassInfoCollector._createStructForClass meets a class's supertypes before it; a Julia class's parent is its supertype and its fields' classes Julia's field types (class_field_type)" Base.fieldcount function _meet_class!(out::Vector{DataType}, seen::Base.IdSet{DataType}, t::DataType, at::String)::Nothing
    t in seen && return nothing
    push!(seen, t)
    push!(out, t)
    _meet_class!(out, seen, supertype(t), at)   # Any's supertype is Any, already met
    # a tuple's record holds top-typed fields, no class of its own (TupleRecord)
    tuple_record_arity(t) === nothing || return nothing
    # a class no value has exactly (class_is_abstract) holds no field: its supertypes alone
    isconcretetype(t) || return nothing
    if Base.iskindtype(t)
        # a kind's instance takes dart's runtime type layout, its fields' classes met as Julia's are
        foreach(f -> _meet_value!(out, seen, f.type, at), _kind_instance_fields(t, at))
    elseif t === Symbol || t === Module
        # a symbol holds its name, a String, and a module its name, a Symbol, outside Julia's fields
        # (_symbol_instance_fields, _module_instance_fields)
        foreach(f -> _meet_value!(out, seen, f.type, at), class_instance_fields(t, at))
    elseif t <: Core.GenericMemory
        # a memory holds its length and its elements, each a value of its element type when the
        # elements are boxed (_memory_instance_fields), and a byte memory its data owner, a String
        _meet_value!(out, seen, Int, at)
        t === Memory{UInt8} && _meet_value!(out, seen, String, at)
        local e = _memory_element_storage(t.parameters[2], at)
        e isa Union && _meet_value!(out, seen, e, at)
    elseif t <: Core.GenericMemoryRef
        # a memory reference holds its offset and its memory (_memoryref_instance_fields)
        foreach(f -> _meet_value!(out, seen, f.type, at), class_instance_fields(t, at))
    else
        foreach(i -> _meet_value!(out, seen, class_field_type(t, i), at), 1:fieldcount(t))
    end
    return nothing
end

# A class's place in the hierarchy, Julia's answers (ledger D3) where dart reads a Kernel Class:
# `cls.superclass`, `cls.isAbstract`, `cls.implementedTypes`. Julia has single inheritance and no
# interfaces or mixins: a class's supertype chain is its superclasses, none is an anonymous mixin,
# and what dart's interfaces give, a subtype off the superclass tree, is Julia's covariant Tuple.

"""
    egal_by_identity(T) -> Bool

Whether Julia's egal (`===`) compares two values of class `T` by identity: a mutable class's, but the
three mutable classes jl_egal compares by content, String (its bytes), SimpleVector (its elements)
and DataType (the type it is), Julia's src/builtins.c jl_egal__unboxed_. The one source of that
rule, read by the code generator's `==` fallback and the intrinsifier's `===`.
"""
@quarantine unpinned "Julia's egal compares a mutable object by identity, except the String, SimpleVector and DataType it compares by content (builtins.c)" Base.ismutabletype function egal_by_identity(T::Type)::Bool
    return T isa DataType && ismutabletype(T) && !(T === String || T === Core.SimpleVector || T === DataType)
end

"""
    class_superclass(c) -> Union{DataType,Nothing}

dart's `cls.superclass`: Julia's `supertype`, `nothing` for `Any`, the root (Julia's own
`supertype(Any)` is `Any`).
"""
@quarantine unpinned "a class's parent is Julia's supertype; Any, the root, has none" Base.supertype class_superclass(c::DataType)::Union{DataType,Nothing} = c === Any ? nothing : supertype(c)

"""
    class_is_abstract(c) -> Bool

dart's `cls.isAbstract`, a class no value has exactly: Julia's `!isconcretetype` (an abstract type,
or a covariant Tuple such as `Tuple{Any}`).
"""
@quarantine unpinned "a class is abstract when no value has it exactly: Julia's isconcretetype" Base.isconcretetype class_is_abstract(c::DataType)::Bool = !isconcretetype(c)

"""
    class_implemented_types(c, classes) -> Vector{DataType}

dart's `cls.implementedTypes`, the classes `c` is a subtype of off its superclass chain, among
`classes` (the closed world's), Julia's `<:` answering each: for a concrete class, every class of
`classes` it is a subtype of that is not on its supertype chain (`Tuple{Int64}` implements
`Tuple{Any}`; `Core.TypeofBottom` implements the open `Type{T}` that `DataType`'s chain holds). A
class that is not concrete implements none: each concrete subtype of a class off the tree is that
class's implementor itself, so a class's ranges (getConcreteClassIdRange) hold every concrete class
Julia's `<:` says is its subtype.
"""
@quarantine unpinned "a class's subtypes off its supertype chain are Julia's <:, its covariant Tuples" Base.supertype function class_implemented_types(c::DataType, classes::Vector{DataType})::Vector{DataType}
    isconcretetype(c) || return DataType[]
    local chain = Base.IdSet{DataType}()
    local s = c
    while s !== Any
        s = supertype(s)
        push!(chain, s)
    end
    return DataType[t for t in classes if t !== c && !(t in chain) && c <: t]
end

"""
    ClassField

dart's Kernel `Field`, an instance field of a class: Julia's field `index` (from 1) of the concrete
class `cls`, its `name`, its declared `type` and whether it is `mutable` (a mutable struct's field
not declared `const`), Julia's answer, which a setter (dispatch_table.jl) reads, a program's write of a const
field raising Julia's own ErrorException (visitInstanceSet, by isconst); for a primitive class, index 0, its one
`value`, the class itself.
`runtime_written`: Julia's runtime writes the field although Julia's own answer is const (a byte
memory's `length`, which jl_genericmemory_to_string sets to 0, julia/src/genericmemory.c:200), so its
wasm struct field is mutable (class_info.jl's FieldType, dart's `mutable: !field.isFinal`,
class_info.dart:599), while `mutable` stays false: no setter is registered, and a program's write raises Julia's
const-field ErrorException.
"""
@quarantine pin"julia/src/julia.h:1629 jl_field_isconst" "Julia's fields are a struct's fieldnames and fieldtypes, its primitive types a value with no field" Core.Type struct ClassField
    cls::DataType
    index::Int
    name::String
    type::Type
    mutable::Bool
    runtime_written::Bool
end

# a field no runtime of Julia's writes past its mutability, every field but a byte memory's `length`
@quarantine pin"julia/src/genericmemory.c:189 jl_genericmemory_to_string" "dart's Kernel Field carries its finality alone; a field Julia's runtime writes past a const is Julia's own (julia/src/genericmemory.c:200 `m->length = 0`)" Core.Type ClassField(cls::DataType, index::Int, name::String, @nospecialize(type::Type), mutable::Bool) =
    ClassField(cls, index, name, type, mutable, false)

"""    type_expand_integer(T) -> Bool

Whether LLVM's type legalizer expands a value of Julia's type `T` into two halves: an integer wider than
the target's largest integer register, i64 on wasm (llvm/lib/Target/WebAssembly/WebAssemblyISelLowering.cpp:64),
takes TypeExpandInteger. Julia's codegen gives every 128-bit primitive class the LLVM integer i128
(julia/src/cgutils.cpp:668 bitstype_to_llvm: the integer of `jl_datatype_size` × 8 bits, its float and
pointer classes being narrower), its 128-bit Base.BitInteger types, Int128 and UInt128, and a `primitive
type P 128` alike; i128 is the simple type computeRegisterProperties expands into two i64 halves, so each
such class is the struct of its two i64 halves (class_instance_fields). A wider integer, or one whose width
is no power of two (an i96, which getTypeConversion's extended-scalar block, :1421-1435, promotes to an
i128 first, its bits above its own undefined), is no two halves of its own and rejects, located, where it
is translated."""
@quarantine pin"julia/src/cgutils.cpp:668 bitstype_to_llvm" "llvm/lib/CodeGen/TargetLoweringBase.cpp:1726 TargetLoweringBase::computeRegisterProperties gives every integer type wider than the largest integer register the action TypeExpandInteger, two halves of the next narrower type; Julia's codegen gives a 128-bit primitive class the integer i128" Base.isprimitivetype function type_expand_integer(@nospecialize(T::Any))::Bool
    return T isa DataType && isprimitivetype(T) && 8 * sizeof(T) == 128
end

"""    managed_pointer(T) -> Bool

Whether `T` is a `Ptr`, whose value WasmTarget holds as a managed pointer: its class's struct of a base
and a byte offset (`_pointer_instance_fields`), never an address. dart's wasm runtime holds a view of bytes
the same way: a ByteData is the data array of its buffer beside the view's `offsetInBytes`, and it reads the
byte at `offsetInBytes + byteOffset` of that array (sdk/lib/_internal/wasm/common/typed_data.dart:92
ByteDataBase, its `offsetInBytes` at :93, I8ByteData's `_data` at :487 read at :515). Here the base is the
WasmGC data array the pointer points into and the offset its byte distance from the array's start, the
address the element holds in Julia's own layout (an element's `elsize` times its index).
precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:92 ByteDataBase). Julia's differs: a `Ptr` is
an integer address (julia/base/boot.jl:968 UInt, a bitcast of its bits), and Julia's codegen keeps an
address into an object apart from that object only in its analyses (its late GC lowering finds a derived
pointer's base, julia/src/llvm-late-gc-lowering.cpp:108 FindBaseValue; a MemoryRef holds its memory beside
the element's address, julia.h jl_genericmemoryref_t). A dart view always has a buffer; a pointer whose
base is no object (C_NULL, `Ptr{T}(n)`) is WasmTarget's base-less pointer whose offset is that integer, and
a base's address as an integer is no value WasmTarget has (rejected at run time where a program reads it,
src/intrinsics.jl's pointer arm).
"""
@quarantine pin"precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:92 ByteDataBase)" "a Ptr is an address; WasmTarget holds its base, the data array it points into, beside its byte offset, as dart's ByteData holds its buffer's data array beside its offsetInBytes; Julia differs: a Ptr is one integer, and a pointer of no object keeps that integer as its offset with no base" Core.Ptr managed_pointer(@nospecialize(T::Any))::Bool =
    T isa DataType && T <: Ptr

"""
    _pointer_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Ptr{T}` (managed_pointer), immutable: `base`, the data array it points into or `nothing`
for a pointer of no object (an integer address: C_NULL, `Ptr{T}(n)`, a union memory's element offset),
and `offset`, the byte offset from the base's first element, or the integer address itself where there is
no base.

Reshaped: Julia's `Ptr` is one machine word, the address; a wasm array has none, so the word is split
into the data array it points into and the byte offset within it, the two fields of dart's byte view
(I8ByteData's final `_data`, sdk/lib/_internal/wasm/common/typed_data.dart:487, and ByteDataBase's final
`offsetInBytes`, :93). Julia's differs: the base is nullable, `nothing` where the address is an integer of
no object, which a dart view, always over a buffer, never is.
"""
@quarantine pin"precedent(dart: sdk/lib/_internal/wasm/common/typed_data.dart:93 ByteDataBase.offsetInBytes)" "a Ptr's address is its base and its byte offset within it, as dart's byte view is its buffer's data array and its final offsetInBytes; Julia differs: a Ptr is one word, and its base is nullable, none for an integer address" Core.Ptr function _pointer_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c <: Ptr || reject!(Internal("src/julia/classes.jl _pointer_instance_fields: $c, no Ptr"), at)
    return ClassField[ClassField(c, 0, "base", Union{Nothing,WasmEqRef}, false), ClassField(c, 0, "offset", UInt64, false)]
end

"""    type_promote_integer(T) -> Union{Type{UInt32},Type{UInt64},Nothing}

The integer register that holds a value of the primitive class `T`, one with no builtin type
(Translator.builtinTypes), as Julia's integer class of its width whose builtin type is that register
(`UInt32` the i32, `UInt64` the i64), or `nothing` where LLVM's wasm target holds it in none. Julia's codegen gives a
primitive class its LLVM type (julia/src/cgutils.cpp:668 bitstype_to_llvm): `Float16` and `BFloat16`
their float types, a `Ptr` the pointer of address space 0, an `LLVMPtr` the pointer of its own, and any
other the integer of its size in bits (`jl_datatype_size` × 8: `Core.AddrSpace` an i8, a `primitive type
P 40` an i40). Julia hands LLVM its `half` on wasm (julia/src/llvm-demote-float16.cpp:52 have_fp16, false on
PPC alone), and wasm has no f16: LLVM's type legalizer soft-promotes it (llvm/lib/CodeGen/TargetLoweringBase.cpp:1820,
TypeSoftPromoteHalf, useFPRegsForHalfType false on wasm), its value its 16 bits in the register of an i16, the
i32: `Float16` is held as a 16-bit integer is, its operations the intrinsifier's soft-promoted half (src/intrinsics.jl
Val(:half)). LLVM's type legalizer holds an integer narrower than a legal one in the next legal one,
TypePromoteInteger (llvm/lib/CodeGen/TargetLoweringBase.cpp:1754 for a simple type; :1421-1435 getTypeConversion's extended-scalar block
rounds an extended one, an i24 or an i40, up to its power of two first), wasm's legal integers being i32
and i64 (llvm/lib/Target/WebAssembly/WebAssemblyISelLowering.cpp:63-64); a pointer of address space 0 is the
integer of the data layout's pointer width, the 64 bits native Julia's `sizeof(Ptr{T})` answers on this
host. A 128-bit integer (i128) is TypeExpandInteger's (type_expand_integer); a wider integer, or one
whose width is no power of two, is not yet ported and rejects; `BFloat16` (soft-promoted as
`half` is, its conversions not ported) and an `LLVMPtr` a pointer of another address space: each `nothing`,
rejected, located, where it is translated.

The register's bits above the class's own are LLVM's promoted value's, undefined: an operation that reads
them is the promoted operation's (LegalizeIntegerTypes.cpp PromoteIntOp), which the intrinsics port
apart; one not ported rejects there, located."""
@quarantine pin"julia/src/cgutils.cpp:668 bitstype_to_llvm" "Julia's codegen gives a primitive class with no wasm builtin type its LLVM integer type, which LLVM's wasm type legalizer promotes to the next legal register (llvm/lib/CodeGen/TargetLoweringBase.cpp:1726 TargetLoweringBase::computeRegisterProperties, its TypePromoteInteger loop at :1754); dart's builtin types are a closed set of its wasm classes" Base.isprimitivetype function type_promote_integer(@nospecialize(T::Any))::Union{Type{UInt32},Type{UInt64},Nothing}
    T isa DataType && isprimitivetype(T) || return nothing
    (T === Core.BFloat16 || T <: Core.LLVMPtr) && return nothing
    # a Ptr is a managed pointer, its class's struct of a base and an offset (managed_pointer)
    managed_pointer(T) && return nothing
    local bits = 8 * sizeof(T)
    bits <= 32 && return UInt32
    bits <= 64 && return UInt64
    return nothing
end

"""    primitive_value_type(translator, cls) -> Union{WasmBuilder.IR.StorageType,Nothing}

The wasm type that holds a value of the primitive class `cls` unboxed, or `nothing` where it has none:
its builtin type (Translator.builtinTypes), else the builtin type of the register LLVM promotes it to
(type_promote_integer). The one source of which primitive classes are value classes: translateStorageType
unboxes a value by it, preciseThisFor unboxes a promoted class's `this` by it, and
FunctionCollector.initialize records each one's box allocated, as dart records its value classes
(functions.dart:71)."""
@quarantine pin"julia/src/cgutils.cpp:668 bitstype_to_llvm" "a Julia primitive class holds its value in a wasm number type, a builtin one or the register LLVM promotes its LLVM integer to; dart's value classes are a closed set of builtin types" Base.get function primitive_value_type(translator, cls::DataType)::Union{WasmBuilder.IR.StorageType,Nothing}
    local builtin = get(translator.builtin_types[], cls, nothing)
    builtin === nothing || return builtin
    local promoted = type_promote_integer(cls)
    return promoted === nothing ? nothing : translator.builtin_types[][promoted]
end

"""    register_constant_class(translator, cls) -> Bool

Whether a constant of the class `cls` is its integer register's literal, dart's instance constant of a
wasm value class (constants.dart:690 ConstantInstantiator.visitInstanceConstant, `wasmI32Class` and
`wasmI64Class`): a primitive class with no builtin type (Translator.builtinTypes) held in the register
LLVM promotes its integer to (type_promote_integer: an enum, `Core.AddrSpace`, a `primitive type P 40`; a `Ptr`
is a managed pointer, its class's struct, managed_pointer). Julia's codegen makes such a constant the integer of its bits (julia/src/intrinsics.cpp:188
julia_const_to_llvm: an APInt of 8 * jl_datatype_size bits, a pointer its inttoptr). The one source of
which instance constants are a register's literal: constants.jl's instantiator pushes them, its
creator makes none, and constant_unmade reads it. Read from primitive_value_type, the one source of a
primitive class's register: a class it gives one that is no builtin type's."""
@quarantine pin"julia/src/intrinsics.cpp:188 julia_const_to_llvm" "a Julia constant of a primitive class held in an integer register is the integer of its bits, as dart's wasm value classes' instance constants are their register's literal; dart's are a closed set of classes, Julia's every primitive class with no builtin type held in i32 or i64" Base.haskey register_constant_class(translator, cls::DataType)::Bool =
    primitive_value_type(translator, cls) !== nothing && !haskey(translator.builtin_types[], cls)

"""
    class_field_type(c, i) -> Type

The type Julia declares for the field `i` of the struct `c`, the type of the values its runtime holds
there: `fieldtype`, Julia's answer, read from the type's `types` (julia/src/jltypes.c:2945 jl_init_types
builds a builtin's). For `Core.TypeName`'s `linearcache` the two disagree at the pin: jl_init_types's
`types` (julia/src/jltypes.c:3019, the entry at :3023) declares it a `Core.MethodCache`, and the fixups
after it (:3844-3855) reassign other slots but not this one, while the field's storage is
`_Atomic(jl_svec_t*) linearcache` (julia/src/julia.h:534) and Julia's runtime writes it a SimpleVector
every time (julia/src/datatype.c:82, julia/src/jltypes.c:1236). The field's type here is the storage's:
`Core.SimpleVector` where the running Julia declares `Core.MethodCache`, and `fieldtype` wherever the
declaration is the storage's already. The one source of a field's type for a class's layout
(`class_instance_fields`), `field_may_be_null` and the class walk (`_meet_class!`).

How Julia 1.12 differs: its inference trusts the declared `Core.MethodCache` (`getfield_tfunc`), so a
program's read of the field is typed by a class the field never holds; such a read or write rejects,
located, at the access (`declared_type_unheld`), never the SimpleVector converted to that type.
"""
@quarantine pin"julia/src/jltypes.c:2945 jl_init_types" "Julia 1.12's jl_init_types declares TypeName's linearcache a Core.MethodCache (julia/src/jltypes.c:3023) while its storage is a jl_svec_t* (julia/src/julia.h:534) that the runtime writes a SimpleVector (julia/src/datatype.c:82, julia/src/jltypes.c:1236); the field's type is its storage's; Julia differs: its fieldtype answers the declaration" Base.fieldtype function class_field_type(c::DataType, i::Int)::Type
    local t = fieldtype(c, i)
    c === Core.TypeName && fieldname(c, i) === :linearcache && t === Core.MethodCache && return Core.SimpleVector
    return t
end

"""
    declared_type_unheld(c, i) -> Union{Rejection,Nothing}

Why a program's access of the field `i` of the struct `c` gives no value of Julia's, or `nothing`: a struct's field whose
type (`class_field_type`) is not the one the running Julia declares (`fieldtype`), Julia 1.12's
`Core.TypeName` `linearcache`, which its inference types `Core.MethodCache` (`getfield_tfunc`) while it
holds a SimpleVector: the typed IR's answer for that read is Julia's unsound one (on 1.12.7,
`typeof(tn.linearcache) === Core.SimpleVector` folds to false while the value held is one), so the access is Unquarantined, located,
never the SimpleVector cast to the declared class.
"""
@quarantine pin"julia/src/jltypes.c:2945 jl_init_types" "Julia 1.12's inference types an access of TypeName's linearcache by the declared Core.MethodCache (julia/src/jltypes.c:3023), a class the field never holds (julia/src/julia.h:534); WasmTarget holds the SimpleVector, so an access answers no value of Julia's" Base.fieldtype function declared_type_unheld(c::DataType, i::Int)::Union{Rejection,Nothing}
    1 <= i <= fieldcount(c) || return nothing   # index 0, a field that is not Julia's (ClassField)
    local declared, held = fieldtype(c, i), class_field_type(c, i)
    held === declared && return nothing
    return Unquarantined("src/julia/classes.jl class_field_type: an access of the field $(fieldname(c, i)) of $c, which Julia's inference types $declared, a type the field never holds (it holds $held, julia/src/julia.h:534)")
end

"""
    class_instance_fields(c, at) -> Vector{ClassField}

dart's `cls.fields.where((f) => f.isInstanceMember)`, a class's own instance fields, Julia's answers:
an abstract class has none (Julia's abstract types have no fields, so every field is a concrete
class's own); a primitive class (`Int64`, `Bool`, `Float64`, ...) has its one `value`, as dart's
boxed classes do (`_BoxedInt.value`); a struct has its `fieldnames` and `fieldtypes`; a singleton
none, and so does a mutable struct declared with no fields, each instance an object of its own; a kind (a type as a value) dart's runtime type layout (`_kind_instance_fields`); a
`Core.SimpleVector` its elements as one immutable wasm array (`_svec_instance_fields`); a `String`
its UTF-8 code units as one immutable i8 wasm array (`_string_instance_fields`); a `Symbol` its name,
one String (`_symbol_instance_fields`); a `Module` its name, one Symbol (`_module_instance_fields`). Any
other class whose data Julia holds outside its fields rejects, located, until its representation is
written. After a struct's own fields come their set flags (`class_is_set_field`), one per field an
allocation may leave undefined whose type admits `nothing`, dart's late lowering's `#isSet` fields.
"""
@quarantine pin"pkg/dart2wasm/lib/class_info.dart:539 ClassInfoCollector._generateFields" "pkg/dart2wasm/lib/class_info.dart:539 ClassInfoCollector._generateFields reads a class's instance fields; a Julia class's are its fieldnames, fieldtypes and isconst, a primitive type holding one value" Base.isconst function class_instance_fields(c::DataType, at::String)::Vector{ClassField}
    class_is_abstract(c) && return ClassField[]
    # a tuple's record (TupleRecord): a top-typed field per element, dart's record fields $1..$N
    local arity = tuple_record_arity(c)
    arity === nothing || return @exhaustive arity::RecordArity begin
        (f::FixedArity) => Dart2Wasm._generate_fields(Dart2Wasm._RecordClassGenerator(Dict{Dart2Wasm.RecordShape,DataType}()), Dart2Wasm.RecordShape(f.n, String[]))
        # the array class's one field, the argument buffer jl_f__apply_iterate fills (julia/src/builtins.c:738
        # arg_heap), dart's positional arguments array (translator.dart:262 nullableObjectArrayTypeRef): a
        # mutable array, filled at a run-time length, its elements top-typed
        RunTimeArity => ClassField[ClassField(c, 0, "data", WasmArray{Any}, false)]
    end
    # a 128-bit primitive class (Int128, UInt128, a `primitive type P 128`: type_expand_integer): its two 64-bit halves, LLVM's legalization of an i128 on a
    # 64-bit target (llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp, ExpandIntegerResult:
    # the low and the high i64), each a field of the class's struct, as the value is one wasm value
    isprimitivetype(c) && type_expand_integer(c) &&
        return ClassField[ClassField(c, 0, "lo", UInt64, false), ClassField(c, 0, "hi", UInt64, false)]
    managed_pointer(c) && return _pointer_instance_fields(c, at)
    isprimitivetype(c) && return ClassField[ClassField(c, 0, "value", c, false)]
    Base.iskindtype(c) && return _kind_instance_fields(c, at)
    if fieldcount(c) == 0
        Base.issingletontype(c) && return ClassField[]
        c === Core.SimpleVector && return _svec_instance_fields(c, at)
        c === String && return _string_instance_fields(c, at)
        c === Symbol && return _symbol_instance_fields(c, at)
        c === Module && return _module_instance_fields(c, at)
        # a mutable struct declared with no fields holds nothing: Julia's layout has no field
        # (fieldcount 0, nothing outside it), its identity the object's own; Julia's own types above,
        # mutable by Julia's account too, hold theirs outside their fields
        ismutabletype(c) && return ClassField[]
        reject!(Unquarantined("src/julia/classes.jl class_instance_fields: $c, whose data Julia holds outside its fields"), at)
    end
    c <: Core.GenericMemory && return _memory_instance_fields(c, at)
    c <: Core.GenericMemoryRef && return _memoryref_instance_fields(c, at)
    local fields = ClassField[ClassField(c, i, string(fieldname(c, i)), class_field_type(c, i), ismutabletype(c) && !isconst(c, i)) for i in 1:fieldcount(c)]
    for i in 1:fieldcount(c)
        local flag = class_is_set_field(fields[i])
        flag === nothing || push!(fields, flag)
    end
    return fields
end

"""
    holds_reference(T) -> Bool

Whether a slot of type `T` holds a reference Julia's NULL can stand in, its #undef: one Julia stores
boxed (`jl_field_isptr`, a memory's `arrayelem_isboxed`), or inline holding a pointer
(`jl_type_hasptr`, a memory's `first_ptr >= 0`). An inline slot of bits (a primitive, an isbits
struct, an isbits union) is never #undef: it holds bits.
"""
@quarantine pin"julia/src/cgutils.cpp:2768 field_may_be_null" "julia/src/cgutils.cpp:2768 field_may_be_null tests a slot's reference as jl_field_isptr || jl_type_hasptr" Base.allocatedinline holds_reference(@nospecialize(T))::Bool =
    !Base.allocatedinline(T) || (T isa DataType && !Base.datatype_pointerfree(T))

"""
    generic_memory_elsize(M, add_isunion) -> Int

The element size of the concrete memory type `M`, the constant arm of Julia's codegen's
emit_genericmemoryelsize, read from the type's own layout: its size, plus the selector byte of an
isbits union (`arrayelem_isunion`, `Base.datatype_arrayelem`'s 2) where `add_isunion`.
"""
@quarantine pin"julia/src/cgutils.cpp:3292 emit_genericmemoryelsize" "julia/src/cgutils.cpp:3292 emit_genericmemoryelsize: a memory type's element size is its layout's size, plus an isbits union's selector byte where add_isunion" Base.datatype_layoutsize generic_memory_elsize(M::DataType, add_isunion::Bool)::Int =
    Base.datatype_layoutsize(M) + (add_isunion && Base.datatype_arrayelem(M) == 2 ? 1 : 0)

"""
    field_may_be_null(c, i) -> Bool

Whether field `i` of the struct `c` may be undefined (#undef), Julia's codegen's answer: a field past
the ones every constructor assigns (the trailing `n_uninitialized` of its type's name,
`Core.Compiler.datatype_min_ninitialized`) holding a reference (`holds_reference`).
"""
@quarantine pin"julia/src/cgutils.cpp:2768 field_may_be_null" "julia/src/cgutils.cpp:2768 field_may_be_null: a field past n_uninitialized's start holding a reference" Core.Compiler.datatype_min_ninitialized field_may_be_null(c::DataType, i::Int)::Bool =
    1 <= i <= fieldcount(c) && i > Core.Compiler.datatype_min_ninitialized(c) && holds_reference(class_field_type(c, i))

"""
    class_is_set_field(field) -> Union{ClassField,Nothing}

The set flag of a struct's field, or nothing: a field that may be undefined (`field_may_be_null`)
whose type admits `nothing` (`_needs_is_set`) keeps dart's late lowering's flag, named after it with
`#isSet` (late_lowering.dart:12 lateIsSetSuffix), a Bool, mutable where the field is, at index 0, not
one of Julia's fields. An allocation stores it true for a field it is given and false for one it
leaves out, a write sets it (late_lowering.dart:382), a read raises UndefRefError on false where dart's
getter throws (:295), and `isdefined` reads it. Every other field that may be undefined keeps the
null for #undef (useNull). The one test the layout, an allocation, a read, a write and `isdefined` ask.
"""
@quarantine pin"pkg/front_end/lib/src/kernel/late_lowering.dart:12 lateIsSetSuffix" "pkg/front_end/lib/src/kernel/late_lowering.dart:12 lateIsSetSuffix names a potentially nullable late slot's set flag (useIsSetField)" Core.Bool function class_is_set_field(field::ClassField)::Union{ClassField,Nothing}
    field.index > 0 && field_may_be_null(field.cls, field.index) && _needs_is_set(field.type) || return nothing
    return ClassField(field.cls, 0, field.name * "#isSet", Bool, field.mutable)
end

"""
    _kind_instance_fields(c, at) -> Vector{ClassField}

The fields of a kind's instance, a type as a value: dart's runtime type objects (`_Type` and its
subclasses, sdk/lib/_internal/wasm/lib/type.dart), whose fields class_info.dart's FieldIndex names.
Each kind first holds dart's `_Type.isDeclaredNullable` (FieldIndex.typeIsDeclaredNullable), which is
Julia's `Nothing <: T`: `Nothing` is dart's Null and `Any` dart's `Object?`, both nullable. A
`DataType` is dart's `_InterfaceType`: `classId` (FieldIndex.interfaceTypeClassId) is the id of the
class the type denotes, and dart's `typeArguments` (FieldIndex.interfaceTypeTypeArguments,
sdk/lib/_internal/wasm/common/type.dart:277 `final WasmArray<_Type> typeArguments;`) is Julia's own
field `parameters`, at Julia's own index and of Julia's declared type (`Core.SimpleVector`), read
from `Base.fieldindex` and `fieldtype`, so `T.parameters` reads it. `Union` and `UnionAll` have no dart
counterpart and keep Julia's own fields (`a`, `b`; `var`, `body`), each a value of any class.
`Union{}`'s kind, `Core.TypeofBottom`, is dart's `_BottomType` and holds nothing more. The two fields
that are not Julia's take index 0, like a primitive class's `value`.

precedent(dart: the runtime type classes of sdk/lib/_internal/wasm/lib/type.dart, laid out by
class_info.dart like any class). Julia's differs: its kinds are runtime classes whose own fields
(`DataType.name`, `.parameters`, ...) are Julia's internals, so a type value takes dart's layout
where dart has one, and Julia's own fields where only Julia has the kind.
"""
@quarantine unpinned "a type is a value in Julia, its class a kind whose own fields are the runtime's internals" Core.TypeofBottom function _kind_instance_fields(c::DataType, at::String)::Vector{ClassField}
    local nullable = ClassField(c, 0, "isDeclaredNullable", Bool, false)
    c === DataType && return ClassField[nullable, ClassField(c, 0, "classId", Int32, false),
        ClassField(c, Base.fieldindex(c, :parameters), "parameters", fieldtype(c, :parameters), false)]
    c === Union && return ClassField[nullable, ClassField(c, 1, "a", Any, false), ClassField(c, 2, "b", Any, false)]
    c === UnionAll && return ClassField[nullable, ClassField(c, 1, "var", Any, false), ClassField(c, 2, "body", Any, false)]
    c === Core.TypeofBottom && return ClassField[nullable]
    reject!(Internal("src/julia/classes.jl _kind_instance_fields: $c, no kind of Julia's"), at)
end

"""
    KindFieldTable

One of Julia's own fields of a DataType that its type value's layout (`_kind_instance_fields`, dart's
`_InterfaceType`) does not hold, as a table by class id: `values[id + 1]` the field's value of the class
`id`'s type value (an element of `type`), and `states[id + 1]` what that entry is: `KIND_ENTRY_SET`
(the value is Julia's), `KIND_ENTRY_UNDEF` (Julia's #undef, which jl_f_getfield raises UndefRefError
for) or `KIND_ENTRY_GAP` (a value no constant of the closed world holds, `gap` saying which, the fatal
arm at its read). `values` is `nothing` where no entry is set (a field whose every entry is a gap).
formal(dev/formal/KindFieldTable.tla) ReadAgrees, ReadAnswers: the state is kept beside the value, so a
null value (Julia's `nothing`, Nothing's `instance`) is never read as #undef or a gap as `nothing`.
"""
@quarantine pin"julia/src/julia.h:626 jl_datatype_t" "a DataType's fields dart's _InterfaceType does not hold, each a table by class id as dart keeps a per-class runtime fact (pkg/dart2wasm/lib/types.dart:1424 _getTypeNames), its entries' states beside their values" Core.DataType struct KindFieldTable
    field::Symbol
    type::Type
    values::Union{Nothing,Vector{Any}}
    states::Vector{UInt8}
    gap::String
end

@quarantine pin"julia/src/builtins.c:1023 jl_f_getfield" "julia/src/builtins.c:1023 jl_f_getfield answers a set field's value" Core.UInt8 const KIND_ENTRY_SET = UInt8(1)
@quarantine pin"julia/src/builtins.c:1023 jl_f_getfield" "julia/src/builtins.c:1023 jl_f_getfield reads the field by jl_get_nth_field_checked, which raises UndefRefError for a field that is #undef" Core.UInt8 const KIND_ENTRY_UNDEF = UInt8(0)
@quarantine pin"julia/src/init.c:194 jl_exit" "a value no constant of the closed world holds ends the program at its read, located, as Julia's runtime ends one it cannot continue (julia/src/init.c:194 jl_exit), the fatal arm (src/intrinsics.jl Val(:fatal))" Core.UInt8 const KIND_ENTRY_GAP = UInt8(2)

"""
    kind_field_table(translator, i, at) -> KindFieldTable

The table of DataType's field `i`, one of Julia's own (julia/src/julia.h:605-626 jl_datatype_t: name,
super, parameters, types, instance, layout, hash, flags) that the type value's layout does not hold
(`_kind_instance_fields` holds `parameters`). Its entries are the classes' in class id order
(`type_value_entries`, the typeof table's, the one list of the type values the program holds): a class
with no type value is a gap no read reaches. Each of Julia's fields, by its value in the compiling
process (each fixed when Julia makes the type; `hash` the compiling process's, as datatype_hash folds it):
- `super`, a DataType: set where its type value is one the table holds (a class's supertype is a class,
  closed_world_classes), else a gap. A table, never a field: `Any.super === Any` (julia/src/jltypes.c:2966)
  would be a constant cycle, which constants refuse (dev/formal/Constants.tla CyclesReject).
- `types`, a SimpleVector of the field types: #undef where Julia has not computed it, set where every
  element is a value a constant holds (`_kind_value_held`), else a gap.
- `instance`, a singleton's one value: #undef for every other type; set where its class is one a constant
  of is made (a singleton has no fields), else a gap.
- `hash` (Int32) and `flags` (UInt16): bits, always set.
- `name`, Julia's TypeName (julia.h jl_typename_t), and `layout`, a host address (`const
  jl_datatype_layout_t *`): every entry a gap. No TypeName is a class of the closed world (its layout,
  with Julia's method caches, is not ported) and a WasmGC module has no addresses.
"""
# The Julia fields of a class its class layout does not hold that a table by class id does (kind_field_table): a
# DataType's (jl_datatype_t, julia/src/julia.h:605-626) whose type value holds dart's _InterfaceType layout (classId,
# typeArguments = Julia's parameters), so name, super, types, instance, layout, hash and flags; no other class's.
# The one statement of which fields those are: getfield's constant arm, its run-time switch and the dispatch
# table's getter targets each read it
@quarantine pin"julia/src/julia.h:626 jl_datatype_t" "a DataType's own fields its type value's layout does not hold, each read from its table by class id" Core.DataType function kind_table_fields(c::DataType, at::String)::Vector{ClassField}
    c === DataType || return ClassField[]
    local layout = class_instance_fields(c, at)
    return ClassField[ClassField(c, i, string(fieldname(c, i)), fieldtype(c, i), false) for i in 1:fieldcount(c) if !any(f -> f.index == i, layout)]
end

@quarantine pin"julia/src/julia.h:626 jl_datatype_t" "a DataType's own fields in the compiling process, each by its class's type value, its #undef kept as Julia's" Core.DataType function kind_field_table(translator, i::Int, at::String)::KindFieldTable
    local f = fieldname(DataType, i)
    local entries = type_value_entries(translator)
    local held = Base.IdSet{DataType}(e for e in entries if e !== nothing)
    local n = length(entries)
    f in (:name, :layout) && return KindFieldTable(f, fieldtype(DataType, i), nothing, fill(KIND_ENTRY_GAP, n),
        f === :name ? "julia/src/julia.h jl_typename_t: a DataType's name, a TypeName, which no class of the closed world holds (its layout, with Julia's method caches, is not ported)" :
                      "julia/src/julia.h:611 jl_datatype_t.layout: a host address, which a WasmGC module does not have")
    f in (:super, :types, :instance, :hash, :flags) ||
        reject!(Internal("src/julia/classes.jl kind_field_table: DataType's field $f, which the type value's layout holds or Julia does not have"), at)
    local type = f === :super ? Union{Nothing,DataType} : f === :types ? Union{Nothing,Core.SimpleVector} :
                 f === :instance ? Any : fieldtype(DataType, i)
    local values = Vector{Any}(undef, n)
    local states = Vector{UInt8}(undef, n)
    for (k, e) in enumerate(entries)
        local (state, value) = if e === nothing
            (KIND_ENTRY_GAP, nothing)
        elseif !isdefined(e, f)
            (KIND_ENTRY_UNDEF, nothing)
        else
            local v = getfield(e, f)
            local ok = f === :super ? v in held :
                       f === :types ? constant_unmade(translator, Core.SimpleVector) === nothing && all(x -> _kind_value_held(translator, held, x), v) :
                       f === :instance ? constant_unmade(translator, typeof(v)) === nothing && fieldcount(typeof(v)) == 0 :
                       true
            ok ? (KIND_ENTRY_SET, v) : (KIND_ENTRY_GAP, nothing)
        end
        states[k] = state
        # an entry that is not set holds no value of Julia's: its state is read first and raises or ends the
        # program; a bits table's slot is its type's zero, the reference tables' the null, neither ever read
        values[k] = state == KIND_ENTRY_SET ? value : isbitstype(type) ? zero(type) : nothing
    end
    local gap = "julia/src/julia.h:605 jl_datatype_t.$f of a type whose value there no constant of the closed world holds"
    return KindFieldTable(f, type, values, states, gap)
end

# whether a constant of the closed world holds `x`, an element of a type value's `types`: a type value of
# the table (`held`), a Union or UnionAll of held ones where its kind is a class, Union{}; else a value of a
# class a constant of is made (constant_unmade, the one source)
@quarantine pin"dart2wasm/lib/constants.dart:908 ConstantCreator.visitInstanceConstant" "dart2wasm/lib/constants.dart:908 ConstantCreator.visitInstanceConstant makes a constant of a class the closed world holds; a type value's, the typeof table's" Core.typeof function _kind_value_held(translator, held::Base.IdSet{DataType}, @nospecialize(x))::Bool
    x === Union{} && return true
    x isa DataType && return x in held
    x isa Union && return constant_unmade(translator, Union) === nothing &&
        _kind_value_held(translator, held, x.a) && _kind_value_held(translator, held, x.b)
    x isa UnionAll && return constant_unmade(translator, UnionAll) === nothing && constant_unmade(translator, TypeVar) === nothing &&
        _kind_value_held(translator, held, x.var.lb) && _kind_value_held(translator, held, x.var.ub) &&
        _kind_value_held(translator, held, x.body)
    x isa TypeVar && return false
    return constant_unmade(translator, typeof(x)) === nothing
end

"""
    _svec_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Core.SimpleVector`, whose data Julia holds outside its fields: one field, `data`,
of type `ImmutableWasmArray{eltype(c)}` (src/julia/wasm_array.jl), the elements as one immutable
wasm array of references. The ruling, from its two sources:

- Julia's layout (julia.h:155, `jl_svec_t`): "A SimpleVector is an immutable pointer array", its
  `length` then its `jl_value_t *data[]`. So the elements are references to values of any class
  (`eltype(Core.SimpleVector)`, read here: `Any`), as many as its length, and immutable: Core binds
  `svec`, `_svec_len` and `_svec_ref` over it and nothing that writes an element. The wasm array
  carries its own length (`array.len`, what `Core._svec_len` reads), as `jl_svec_t.length` counts
  its data.
- dart's representation of a list of types (sdk/lib/_internal/wasm/common/type.dart:277,
  `final WasmArray<_Type> typeArguments;`): a wasm array of references to the element type's class,
  `arrayTypeForDartType` of it (translator.dart:1205); an immutable one is
  `ImmutableWasmArray<T>` (sdk/lib/_wasm/wasm_types.dart:814), translated with `mutable: false`
  (translator.dart:1094).

A SimpleVector is also a Julia object (it flows into `Any`, `typeof` answers its class), so the
array sits in a field of its class's struct, below the object header, where dart's typeArguments
sits in its `_InterfaceType`. The field is not one of Julia's (a SimpleVector has none), so it
takes index 0, like a primitive class's `value`.

precedent(dart: `_InterfaceType.typeArguments`, a WasmArray<_Type> field; rust: `Box<[T]>`, a
length-carrying slice behind a pointer). Julia's differs: its SimpleVector stores the elements
inline after the length, where wasm's array is an object of its own the struct references.
"""
@quarantine unpinned "a SimpleVector's data lies outside its fields: Julia's jl_svec_t, an immutable pointer array" Core.SimpleVector function _svec_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === Core.SimpleVector || reject!(Internal("src/julia/classes.jl _svec_instance_fields: $c, no SimpleVector"), at)
    return ClassField[ClassField(c, 0, "data", ImmutableWasmArray{eltype(c)}, false)]
end

"""
    _string_instance_fields(c, at) -> Vector{ClassField}

The fields of a `String`, whose data Julia holds outside its fields: one field, `_data`, of type
`WasmArray{WasmI8}` (src/julia/wasm_array.jl), the string's UTF-8 code units as one i8 wasm array,
the field immutable and the array's elements writable, as Julia's runtime fills a fresh String
(`jl_alloc_string`, then Base's `_string` copies the bytes in) and dart2wasm's earlier OneByteString's
`WasmArray<WasmI8>` was; a String is immutable once made by Julia's convention, not by the wasm
type, whose elements a fresh String's maker writes. The ruling (Dale's choice B, 2026-10-29), from its sources:

- Julia's layout (julia.h, `jl_string_len` and `jl_string_data`): a String is its length in bytes
  followed by its UTF-8 code units, immutable; `ncodeunits`, `codeunit`, `sizeof` and iteration
  index those bytes, and `==` compares them. So the field holds exactly the code units, as many as
  `ncodeunits`, the wasm array's own length (`array.len`) counting them as `jl_string_len` does.
- dart's string class (sdk/lib/_internal/wasm/standalone/embedder_string.dart:32,
  `EmbedderStringImpl`): an object of its own class, the object header and then its data, built
  for a literal by translator.dart:2534 `pushStandaloneStringConstant`, which copies the literal's
  code units into the constants' passive data segment and makes a wasm array of them
  (`array.new_data`). At the pin dart's data is a host string reference; dart2wasm's earlier
  `OneByteString` held an i8 wasm array of its code units (the precedent; the pinned checkout is
  shallow, so no commit anchors it). The class shape and the literal path are dart's; the data is
  Julia's, the bytes, so no Julia string operation is a host call. A host string is made only at
  the interop boundary.

Why Julia differs from dart's shape at the pin (a host string reference, `WasmExternRef? _ref`, whose
length and code units are host calls): every String operation in Julia's Base indexes the bytes
(`codeunit`, `ncodeunits`, `sizeof`, `nextind`, iteration, `==` through `memcmp`), so a host string
would make each a host call transcoding between Julia's UTF-8 and the host's UTF-16, a change of
behavior (indices and lengths count UTF-8 bytes in Julia, UTF-16 units in the host) and of
performance alike.

The field is not one of Julia's (a String has none), so it takes index 0, like a primitive class's
`value`.

precedent(dart: EmbedderStringImpl, the header and its data in a field; dart2wasm's earlier
OneByteString, an i8 wasm array of code units; rust: `String`, a UTF-8 byte buffer). Julia's differs:
its String stores the bytes inline after the length, where wasm's array is an object the struct
references.
"""
@quarantine unpinned "a String's data lies outside its fields (Julia's jl_string_len, jl_string_data), its UTF-8 bytes in place of dart's host externref, since Base indexes the bytes; immutable once made by Julia's convention, not by the wasm type" Core.String function _string_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === String || reject!(Internal("src/julia/classes.jl _string_instance_fields: $c, no String"), at)
    return ClassField[ClassField(c, 0, "_data", WasmArray{WasmI8}, false)]
end

"""
    _symbol_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Symbol`, whose data Julia holds outside its fields, in Julia's layout (julia.h:147
`jl_sym_t`): `left` and `right`, the symbol table's two children (`_Atomic(jl_sym_t*)`, a symbol or
none, written once by `_jl_symbol` when a new symbol hangs below), `hash`, the precomputed hash
`mk_symbol` stores (julia/src/symbol.c:45), immutable, and then `_name`, the name (`jl_symbol_name`),
a String, immutable. dart's class (sdk/lib/internal/symbol.dart:16 Symbol, its one field
`final String _name` :18) holds the name as a String, as WasmTarget's does; the tree and the hash are
Julia's. A String's representation is the ruling's (`_string_instance_fields`), so a symbol's name is
one. No field is one of Julia's fields (a Symbol has none), so each takes index 0, like a String's
`_data`.

precedent(dart: dart:_internal's Symbol class, a name String held by an object; Julia's jl_sym_t, a
name held by the interned symbol). Julia's differs: its symbols are interned in one table and compared
by identity; every Symbol of a module, a constant's too (src/constants.jl visit_symbol_constant), is
made by the table's mk_symbol (src/julia/runtime/rtutils.jl _jl_symbol), so one name is one object.
"""
@quarantine pin"julia/src/julia.h:147 jl_sym_t" "a Symbol's data lies outside its fields (Julia's jl_sym_t: left, right, hash, then the name at jl_symbol_name), its name one String as dart's Symbol._name" Core.Symbol function _symbol_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === Symbol || reject!(Internal("src/julia/classes.jl _symbol_instance_fields: $c, no Symbol"), at)
    return ClassField[ClassField(c, 0, "left", Union{Nothing,Symbol}, true), ClassField(c, 0, "right", Union{Nothing,Symbol}, true),
                      ClassField(c, 0, "hash", UInt64, false), ClassField(c, 0, "_name", String, false)]
end

"""
    _memory_element_storage(T, at) -> Type

The element type of the wasm array a `Memory{T}` holds its elements in, by Julia's layout of `T`
(`Base.allocatedinline`, `sizeof`): a primitive element is stored unboxed, dart:_wasm's storage
class of its size (src/julia/wasm_array.jl), a float as WasmF32 or WasmF64, a `Float16` as WasmI16 (LLVM's
soft-promoted half loads and stores its i16, CodeGen/SelectionDAG/LegalizeFloatTypes.cpp:2996
SoftPromoteHalfRes_LOAD and :3401 SoftPromoteHalfOp_STORE, read zero-extended as an unsigned element is) and any
other as WasmI8, WasmI16, WasmI32 or WasmI64 (another 16-bit float, `BFloat16`, rejected, located); every other element is stored boxed, `Union{T,Nothing}`, a nullable
reference to its class (the top type for `Any`), null an element no write has set (#undef).

Reshaped: `T` — an element type Julia stores inline as a union of bits types (`Union{Nothing,Int}`,
allocatedinline, its selector bytes after the data, genericmemory.c `jl_genericmemory_typetagdata`)
is stored boxed, its answers the same, as is an inline struct of bits, whose class a box holds.

Reshaped: a 128-bit primitive element (`Int128`, `UInt128`, a `primitive type P 128`) — Julia stores it
inline, 16 bytes (julia/src/genericmemory.c:95 `elsz`, its layout's size), which LLVM's wasm target
stores as its two i64 halves (llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp ExpandIntOp_STORE); its
value is already its class's immutable struct of the two halves (type_expand_integer, class_instance_fields),
so the array holds that struct by reference, as it holds a managed pointer's and an inline struct of bits'.
precedent(dart: a WasmArray<T> of a class T holds each element by reference, translateStorageType of the class
unboxed off). The struct is immutable, so a write storing the reference copies the value as Julia's store of
the 16 bytes does: no write through one element reaches another.
"""
@quarantine pin"julia/src/genericmemory.c:55 _new_genericmemory_" "a Memory's element storage is Julia's layout of its element type, julia/src/genericmemory.c:55 _new_genericmemory_'s element size: inline bits by size, else a reference" Base.isprimitivetype function _memory_element_storage(@nospecialize(T), at::String)::Type
    # a pointer is a managed pointer, its class's struct (managed_pointer), held by reference
    managed_pointer(T) && return Union{T,Nothing}
    # a 128-bit integer is its class's struct of two i64 halves (type_expand_integer), held by reference
    type_expand_integer(T) && return Union{T,Nothing}
    if T isa DataType && isprimitivetype(T)
        local n = sizeof(T)
        T <: AbstractFloat && n == 4 && return WasmF32
        T <: AbstractFloat && n == 8 && return WasmF64
        T === Float16 && return WasmI16
        !(T <: AbstractFloat) && n == 1 && return WasmI8
        !(T <: AbstractFloat) && n == 2 && return WasmI16
        !(T <: AbstractFloat) && n == 4 && return WasmI32
        !(T <: AbstractFloat) && n == 8 && return WasmI64
        reject!(Unquarantined("src/julia/classes.jl _memory_element_storage: the primitive element type $T, $n bytes, with no wasm storage class"), at)
    end
    return Union{T,Nothing}
end

"""
    _memory_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Memory{T}` (`GenericMemory{:not_atomic,T,Core.CPU}`), whose elements Julia holds
outside its fields: `data`, the elements as one mutable wasm array (`WasmArray` of
`_memory_element_storage(T)`), at index 0, and Julia's own `length`, an `Int`, at its index 1, both
immutable. Julia's layout (julia.h `jl_genericmemory_t` at v1.12.7): `length`, then `ptr`, the
address of the elements stored inline after it. `ptr` is left out: a host address, read only through
`pointer` and `unsafe_load`, foreigncalls the strict subset rejects; the elements are the array.
Only `memorynew` writes `data` and `length`, `length` the array's length, and no setter exists for
either, so the two cannot diverge (D6), with one exception Julia makes: a byte memory a String takes
(jl_genericmemory_to_string, julia/src/genericmemory.c:200 `m->length = 0`) is left of length 0, its
array kept, so its `length`'s wasm field is mutable (`Memory{UInt8}`'s alone, `runtime_written`) and that
take is its one writer (src/intrinsics.jl), Julia's field staying const: no setter, and a program's write raises
Julia's const-field ErrorException; every element access is bounded by `length`, never by the array's. Julia leaves an undefined bits element's contents
unspecified, so the zero a new wasm array holds is one of Julia's own values, never a default past
a gap (D9). An atomic memory (`AtomicMemory`) or another address space rejects, located: threads lie
outside the strict subset.

Reshaped: `data#isSet` — dart's late lowering gives a potentially nullable slot one bool flag
(pkg/front_end/lib/src/kernel/late_lowering.dart:560 computeIsSetEncoding, useIsSetField); a memory's
elements are slots of one array, so where they may hold nothing (`_needs_is_set`) their flags are one
array beside it, an i8 each, zero (unset) as a new array holds, a write setting it.

Julia-forced: `data#owner`, a byte memory's alone (`Memory{UInt8}`), its data owner, a `String` or
`nothing`: Julia's data-owner field (julia.h:1326 `jl_genericmemory_data_owner_field`), which
jl_string_to_genericmemory sets to the String whose bytes the memory wraps (julia/src/genericmemory.c:113)
and which, of the memories over another's data, only a byte memory holds (:109-110 allocate its word, a
`jl_memory_uint8_type`'s); codegen
reads it as the memory's owner (julia/src/cgutils.cpp:3371 emit_genericmemoryowner), `nothing` reading as
the memory itself. Every constructor of the struct (src/intrinsics.jl's memorynew and its String wrap,
src/constants.jl's constant) names it; no setter exists.

precedent(dart: list.dart:15 WasmListBase, its `WasmArray<Object?> _data` beside `int _length`;
Julia's jl_genericmemory_t, its length beside its inline data). Julia's differs: a Memory is an
object of its own class (it flows into `Any`), so the array sits in a field of its struct, as a
SimpleVector's does (`_svec_instance_fields`).
"""
@quarantine pin"julia/src/julia.h:181 jl_genericmemory_t" "a Memory's elements lie outside its fields: Julia's jl_genericmemory_t, its length beside its inline data and a byte memory's data owner (julia.h:1326)" Core.GenericMemory function _memory_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c <: Core.GenericMemory || reject!(Internal("src/julia/classes.jl _memory_instance_fields: $c, no GenericMemory"), at)
    c.parameters[1] === :not_atomic && c.parameters[3] === Core.CPU ||
        reject!(Unquarantined("src/julia/classes.jl _memory_instance_fields: $c, an atomic memory or one of another address space"), at)
    local T = c.parameters[2]
    local data = ClassField(c, 0, "data", WasmArray{_memory_element_storage(T, at)}, false)
    # Julia's `length` is const (jltypes.c:3334 memory_constfields), and a byte memory's is written once
    # more, to 0, by Julia's runtime when a String takes it (jl_genericmemory_to_string, genericmemory.c:200)
    local length = ClassField(c, Base.fieldindex(c, :length), "length", fieldtype(c, :length), false, c === Memory{UInt8})
    # elements that may hold nothing, each its set flag (_needs_is_set), as one array beside the data
    local fields = _needs_is_set(T) ? ClassField[data, ClassField(c, 0, "data#isSet", WasmArray{WasmI8}, false), length] :
                   ClassField[data, length]
    # a byte memory's data owner (julia.h:1326, genericmemory.c:109-113)
    c === Memory{UInt8} && insert!(fields, 2, ClassField(c, 0, "data#owner", Union{String,Nothing}, false))
    return fields
end

"""
    _needs_is_set(T) -> Bool

Whether a slot of type `T` that no write has set (Julia's #undef) keeps a separate set flag. dart's
late lowering answers how a slot tells unset apart from its values: under the strategy dart2wasm's
target selects (late_lowering.dart:552 computeIsSetStrategy's useIsSetFieldOrNull, as
pkg/dart2wasm/lib/target.dart:565 declares `supportsLateLoweringSentinel => false`), a slot of a
potentially nullable type keeps a flag, `useIsSetField`, which the setter sets (late_lowering.dart:382)
and the getter tests before reading the slot, throwing when it is false (:295); a slot of any other type
uses null for unset (`useNull`). WasmTarget's `nothing` is dart's null, so a reference slot whose type
admits `nothing` (`Nothing <: T`, potentially nullable) takes the flag; one Julia stores inline
(`Base.allocatedinline`) holds bits, never #undef, and takes none.
"""
@quarantine pin"pkg/front_end/lib/src/kernel/late_lowering.dart:560 computeIsSetEncoding" "pkg/front_end/lib/src/kernel/late_lowering.dart:560 computeIsSetEncoding keeps a potentially nullable slot's set state in a separate flag (useIsSetField); WasmTarget's nothing is dart's null" Base.allocatedinline _needs_is_set(@nospecialize(T))::Bool =
    !Base.allocatedinline(T) && Nothing <: T

"""
    _memoryref_instance_fields(c, at) -> Vector{ClassField}

The fields of a `MemoryRef{T}` (`GenericMemoryRef{:not_atomic,T,Core.CPU}`), immutable: Julia's own
`ptr_or_offset` and `mem`, at Julia's indices 1 and 2, the offset an `Int`, the element's index in
`mem` from 0, and `mem` its `Memory{T}`.

Reshaped: `ptr_or_offset` — Julia's field is a `Ptr{Nothing}`, the element's address, or, for a
memory of union or zero-size elements, its index from 0 (genericmemory.c, `jl_memoryrefoffset`
answering `ptr_or_offset + 1`); a wasm array has no addresses, so the index form, Julia's own, is
the only one.
"""
@quarantine unpinned "a MemoryRef is Julia's element address or index beside its memory; a wasm array has no addresses, so the index" Core.GenericMemoryRef function _memoryref_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c <: Core.GenericMemoryRef || reject!(Internal("src/julia/classes.jl _memoryref_instance_fields: $c, no GenericMemoryRef"), at)
    c.parameters[1] === :not_atomic && c.parameters[3] === Core.CPU ||
        reject!(Unquarantined("src/julia/classes.jl _memoryref_instance_fields: $c, an atomic memory reference or one of another address space"), at)
    return ClassField[ClassField(c, Base.fieldindex(c, :ptr_or_offset), "ptr_or_offset", Int, false),
                      ClassField(c, Base.fieldindex(c, :mem), "mem", fieldtype(c, :mem), false)]
end

"""
    memoryref_union_classes(receiver, key) -> Union{Vector{DataType},Nothing}

The MemoryRef classes of a read of `ptr_or_offset` (named `key`, its name or Julia's field index 1) on a
receiver whose type is a union of concrete MemoryRef classes, or `nothing` for any other read: such a read
builds each class's element address (src/intrinsics.jl memoryref_address) in a switch over the classes,
as dart's DynamicGet switches over the classes holding a field (code_generator.dart:2317 visitDynamicGet).
"""
@quarantine pin"julia/base/pointer.jl:75 unsafe_convert" "a MemoryRef's ptr_or_offset is the element's address; on a union of reference classes each class's read builds its own managed pointer, never a selector's getter of the held index" Core.GenericMemoryRef function memoryref_union_classes(@nospecialize(receiver::Any), @nospecialize(key::Any))::Union{Vector{DataType},Nothing}
    key === :ptr_or_offset || key === 1 || return nothing
    receiver isa Union || return nothing
    local cs = Base.uniontypes(receiver)
    all(c -> c isa DataType && isconcretetype(c) && c <: Core.GenericMemoryRef, cs) || return nothing
    return DataType[c for c in cs]
end

"""
    memoryref_address_unread(field) -> Union{Rejection,Nothing}

Why a read of the field `field` through a getter selector (a receiver of no one class) gives no value of
Julia's, or `nothing` where the field holds Julia's own: a MemoryRef's `ptr_or_offset`
(`_memoryref_instance_fields`) holds the element's index from 0, and Julia's value is the element's address,
which a direct read builds as a managed pointer (src/intrinsics.jl memoryref_address); a selector's getter
reads the field as it is held, so that read is Unquarantined, located, never the index read as an address.
"""
@quarantine pin"julia/base/pointer.jl:75 unsafe_convert" "a MemoryRef's ptr_or_offset is the element's address or, for union or zero-size elements, its index; WasmTarget holds the index, and a selector's getter reads the field as held" Core.GenericMemoryRef function memoryref_address_unread(field::ClassField)::Union{Rejection,Nothing}
    field.cls <: Core.GenericMemoryRef && field.name == "ptr_or_offset" || return nothing
    return Unquarantined("src/julia/classes.jl _memoryref_instance_fields: a read of the ptr_or_offset of a $(field.cls) through a getter selector, which reads the index WasmTarget holds where Julia holds the element's address")
end

# a TypeName's type caches, the hash table `cache` and the list `linearcache` (julia/src/julia.h:533-534): the fields
# Julia's image writer queues without recursing into them and prunes (julia/src/staticdata.c:866-867, :3311-3316), each
# a field of Core.TypeName, checked when the package loads: a Julia that renames one refuses the load, never a walk that
# recurses into a cache under a new name
@quarantine pin"julia/src/staticdata.c:2544 jl_prune_type_cache_hash" "julia/src/staticdata.c:2544 jl_prune_type_cache_hash prunes a TypeName's cache, and :2572 jl_prune_type_cache_linear its linearcache" Core.TypeName const TYPENAME_CACHES::Tuple{Symbol,Symbol} = let names = (:cache, :linearcache)
    for n in names
        n in fieldnames(Core.TypeName) ||
            throw(ConstructionViolation("TYPENAME_CACHES", "$n is no field of Core.TypeName in this Julia ($(join(fieldnames(Core.TypeName), ", "))): the type caches Julia's image writer prunes (julia/src/staticdata.c:3311-3316) are not where src/julia/classes.jl reads them"))
    end
    names
end

# jltypes.c's own macros over a type cache (julia/src/jltypes.c:26-27), each a function of the port
@quarantine pin"julia/src/jltypes.c:26 max_probe" "the C's macro max_probe(size), a type cache's probe bound, is a function of the port" Base.:>> typecache_max_probe(size::Int)::Int =
    size <= 1024 ? 16 : size >> 6
@quarantine pin"julia/src/jltypes.c:27 h2index" "the C's macro h2index(hv, sz), a hash's home slot in a type cache of sz slots, is a function of the port" Base.:& typecache_h2index(hv::UInt64, sz::Int)::Int =
    Int(hv & UInt64(sz - 1))

"""
    cache_insert_type_set!(tab, val, hv) -> Bool

Julia's insert of the type `val`, its hash `hv`, into the hash table `tab` (julia/src/jltypes.c:1149
cache_insert_type_set_, its non-atomic store): from the home slot (h2index), the first empty slot within max_probe
steps, linear and wrapping, or false where none is.
"""
@quarantine pin"julia/src/jltypes.c:1149 cache_insert_type_set_" "a TypeName's hash cache is an open-addressed table of types, linear probing from each type's hash" Core.DataType function cache_insert_type_set!(tab::Vector{Any}, val::DataType, hv::UInt64)::Bool
    local sz = length(tab)
    sz <= 1 && return false
    local iter = 0
    local index = typecache_h2index(hv, sz)
    local orig = index
    local maxprobe = typecache_max_probe(sz)
    while true
        if tab[index + 1] === nothing
            tab[index + 1] = val
            return true
        end
        index = (index + 1) & (sz - 1)
        iter += 1
        (iter <= maxprobe && index != orig) || return false
    end
end

"""
    cache_rehash_set(a, newsz) -> Vector{Any}

Julia's rehash of a type hash table (julia/src/jltypes.c:1203 cache_rehash_set): a table of `newsz` slots rounded up
to a power of two (next_power_of_two, julia/src/support/dtypes.h:212), each type of `a` inserted in `a`'s slot order
by its own hash (cache_insert_type_set!); a table one insert cannot fit doubles and starts over.
"""
@quarantine pin"julia/src/jltypes.c:1203 cache_rehash_set" "a TypeName's hash cache is rebuilt at a new size by inserting its types again, in slot order" Core.DataType function cache_rehash_set(a::Vector{Any}, newsz::Int)::Vector{Any}
    newsz = newsz == 0 ? 0 : nextpow(2, newsz)
    while true
        local newa = Any[nothing for _ in 1:newsz]
        local all_in = true
        for val in a
            val === nothing && continue
            if !cache_insert_type_set!(newa, val::DataType, UInt64(val.hash))
                all_in = false
                break
            end
        end
        all_in && return newa
        newsz <<= 1
    end
end

"""
    typename_cache_pruned(held, tn, f) -> Core.SimpleVector

A TypeName constant `tn`'s type cache, its field `f` (`TYPENAME_CACHES`), as Julia's image writer leaves it: an
entry the program does not otherwise reach is dropped (julia/src/staticdata.c:3311-3316). The program's reach is
`held`, its type values (`type_value_entries`, the typeof table's, the one list of the type values a program holds), as
Julia's is the serialization order. The hash table is jl_prune_type_cache_hash's (:2544): each unreached entry
`nothing`, then the table rehashed to the kept count, at least HT_N_INLINE (cache_rehash_set), so its length and each
type's slot follow from the kept types alone. The list is jl_prune_type_cache_linear's (:2572): its reached entries
in order, then `nothing`. So the constant holds no type the session made and the program never names, and its module
is the same whatever the compiling process made before it.
"""
@quarantine pin"julia/src/staticdata.c:2544 jl_prune_type_cache_hash" "a TypeName's type caches are pruned to the types the image reaches otherwise (julia/src/staticdata.c:2572 jl_prune_type_cache_linear), so a constant holds no type the session made and the program never names" Core.TypeName function typename_cache_pruned(held::Base.IdSet{DataType}, tn::Core.TypeName, f::Symbol)::Core.SimpleVector
    f in TYPENAME_CACHES || reject!(Internal("src/julia/classes.jl typename_cache_pruned: $f, no type cache of a TypeName"), "typename_cache_pruned")
    local cache = getfield(tn, f)::Core.SimpleVector
    local reached(@nospecialize(e))::Bool = e isa DataType && e in held
    if f === :cache
        length(cache) == 0 && return cache
        local pruned = Any[reached(e) ? e : nothing for e in cache]
        local sz = count(e -> e !== nothing, pruned)
        sz < HT_N_INLINE && (sz = HT_N_INLINE)
        return Core.svec(cache_rehash_set(pruned, sz)...)
    end
    local kept = Any[e for e in cache if reached(e)]
    return Core.svec(kept..., ntuple(_ -> nothing, length(cache) - length(kept))...)
end

"""
    _module_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Module`, whose data Julia holds outside its fields (`fieldcount(Module) == 0`): one
field, `name`, of type `Symbol`, immutable, in Symbol's own form (`_symbol_instance_fields`). Julia's
layout (julia.h:806 `jl_module_t` at v1.12.7): `name` (:808), the module's name, which `nameof` reads,
then `parent` (:809) and the bindings (:810), which are left out. `parent` is a cycle an eager
constant cannot build (a root module is its own parent), and a program reads it only through
`parentmodule`, a foreigncall. The bindings are runtime state: `getglobal` of a module known only at
run time is a builtin over them, which the strict subset rejects. A module's identity is the one
instance each module constant is (constants are canonical by `===`). The field is not one of Julia's
(a Module has none), so it takes index 0, like a Symbol's `_name`.

precedent(julia: jl_module_t, its name its first field after the header; dart: none, a library is no
value). Julia's differs: a module is a value a program can hold (a GlobalRef's `mod`, TypeError's
context), so it is a class, its layout Julia's own leading field.
"""
@quarantine unpinned "a Module's data lies outside its fields (Julia's jl_module_t); dart has no library value, so the layout is Julia's own, its leading name" Core.Module function _module_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === Module || reject!(Internal("src/julia/classes.jl _module_instance_fields: $c, no Module"), at)
    return ClassField[ClassField(c, 0, "name", Symbol, false)]
end

# a field's name, its Julia name as text: a struct's field's, or a module binding's
@quarantine pin"pkg/kernel/lib/src/ast/names.dart:25 Name.text" "a Julia field is named by its fieldname, a Symbol or a tuple's position, and a binding by its Symbol, as kernel names a member by its Name's text (pkg/kernel/lib/src/ast/names.dart:25 Name.text)" Core.GlobalRef field_name(field::Union{ClassField,GlobalRef})::String =
    field isa ClassField ? field.name : string(field.name)

"""
    FieldAccessSite(member, index)

A field access's call site: the enclosing member's MethodInstance and the statement's SSA index in its
body, Julia's own name for a statement. dart keys TFA's selector metadata by the member's TreeNode
(DispatchTable.procedureAttributeMetadata); a Julia field access calls no member, so its site is named
by position, which a rebuilt NIR keeps.
"""
@quarantine pin"dart2wasm/lib/dispatch_table.dart:399 DispatchTable.procedureAttributeMetadata" "dart keys TFA's selector metadata by TreeNode (dart2wasm/lib/dispatch_table.dart:399 DispatchTable.procedureAttributeMetadata); a Julia field access has no Member, so the enclosing MethodInstance and the statement's SSA index name its site" Core.MethodInstance struct FieldAccessSite
    member::Core.MethodInstance
    index::Int
end

# a field selector's calls: its field's name, whether it is the setter, its call count, the classes
# its receivers' types admit, and its call sites
@quarantine pin"pkg/vm/lib/metadata/table_selector.dart:10 TableSelectorInfo" "a field selector's calls, Julia's field accesses on receivers its inference left abstract, as TFA counts a selector's calls in its TableSelectorInfo (pkg/vm/lib/metadata/table_selector.dart:10 TableSelectorInfo)" Core.DataType mutable struct FieldSelectorCalls
    const name::String
    const is_setter::Bool
    call_count::Int
    const classes::Vector{DataType}
    const sites::Vector{FieldAccessSite}
end

# the class ids of a type's concrete classes, ClassIdNumbering.getConcreteClassIdRange's ranges read out
# id by id, and their classes, each id's in the translator's class list (dart's translator.classes,
# indexed by class id): the one projection of the one reading, which every site taking a type's
# concrete classes calls
@quarantine pin"dart2wasm/lib/class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange" "a type's concrete classes are the ids dart2wasm/lib/class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange answers, each a class of the translator's list" Core.Type concrete_class_ids(t, T::Type)::Vector{Int} =
    Int[id for r in Dart2Wasm.get_concrete_class_id_range(t.class_id_numbering[], T) for id in r.start:r.end_]
@quarantine pin"dart2wasm/lib/class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange" "a type's concrete classes are the ids dart2wasm/lib/class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange answers, each a class of the translator's list" Core.DataType concrete_classes(t, T::Type)::Vector{DataType} =
    DataType[t.classes[][id + 1].cls for id in concrete_class_ids(t, T)]

# the classes, each with its id, a value of static type `T` has once held at the top type (convertType's
# box): its concrete classes, and the record each concrete tuple class among them is boxed into there
# (TupleRecord; the walk meets every concrete tuple class's record); the one answer of which records an
# operand's value can be, read by typeof's record arms (src/intrinsics.jl to_typeof)
@quarantine pin"dart2wasm/lib/class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange" "a type's concrete classes are the ids dart2wasm/lib/class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange answers; a tuple of a concrete type held at the top type is its arity's record, as dart's convertType boxes a value type on upcast (translator.dart:1597)" Core.Type function top_held_classes(t, T::Type)::Vector{Tuple{Int,DataType}}
    local out = Tuple{Int,DataType}[]
    for (id, c) in zip(concrete_class_ids(t, T), concrete_classes(t, T))
        push!(out, (id, c))
        local r = boxed_record_class(c)
        r === nothing && continue
        # the walk meets every boxed record (closed_world_classes), so its class has one id
        local ids = concrete_class_ids(t, r)
        length(ids) == 1 || reject!(Internal("src/julia/classes.jl top_held_classes: the record $r of the tuple class $c has $(length(ids)) class ids, not the one the walk gives it"), "top_held_classes")
        push!(out, (only(ids), r))
    end
    return unique!(p -> p[2], out)
end

# the classes a field access's receiver of the abstract type `T` holds at run time: its concrete classes
# (getConcreteClassIdRange's one reading), a concrete tuple class held as its arity's record wherever the
# receiver's wasm type is not that tuple's own struct (convertType boxes a tuple flowing into a slot of
# another type, TupleRecord, formal(dev/formal/TupleRecord.tla): no other slot holds a tuple's struct), so
# a read dispatches on the class id the value carries; Julia's nothing is the null. The one answer of a field access's classes, read
# by its selector (DispatchTable.build, field_selector_calls) and its site (visitInstanceGet)
@quarantine pin"pkg/dart2wasm/lib/translator.dart:1597 Translator.convertType" "a value type flowing into a slot of another type is boxed (dart's convertType), a Julia tuple into its arity's record, so a receiver Julia left abstract holds a tuple as the record's class" Core.Tuple function field_receiver_classes(t, @nospecialize(T))::Vector{DataType}
    local rt = Dart2Wasm.translate_type(t, T)
    local own(c::DataType) = rt isa WasmBuilder.IR.RefType && haskey(t.class_info, c) && rt.heap_type === t.class_info[c].struct_
    local out = DataType[]
    for c in concrete_classes(t, T)
        local r = c <: Core.Tuple ? boxed_record_class(c) : nothing
        local held = r === nothing || own(c) ? c : r
        held in out || push!(out, held)
    end
    # Julia's nothing, held as the null (dart's null of a nullable type), whose class is Nothing
    Nothing <: T && !(Nothing in out) && push!(out, Nothing)
    return out
end

# the name of the field Julia's getfield reads at position `f` of a value of the class `c`, or nothing past
# its fields: get_checked_fieldindex (julia/src/builtins.c:994) checks the index against jl_datatype_nfields
# of the value's own type and raises BoundsError of the value and the index past it (:1006 jl_bounds_error).
# A tuple's record (TupleRecord) holds a tuple of its arity, its fields the record's own `$1..$N`; the array
# record's arity only run time knows (TupleRecordArray), a located rejection
@quarantine pin"julia/src/builtins.c:994 get_checked_fieldindex" "Julia's getfield bounds a position by the field count of the value's own type, a tuple's its arity, which a record class holds in fields of its own" Base.fieldcount function field_at_position(c::DataType, f::Int, at::String)::Union{String,Nothing}
    local r = tuple_record_arity(c)
    r === nothing && return 1 <= f <= fieldcount(c) ? string(fieldname(c, f)) : nothing
    return @exhaustive r::RecordArity begin
        (a::FixedArity) => 1 <= f <= a.n ? class_instance_fields(c, at)[f].name : nothing
        RunTimeArity => reject!(Unquarantined("$at: a field access at position $f on $c, a tuple whose arity only run time knows, held with other classes: not yet written"), at)
    end
end

# the classes among `admitted` that a field access by the constant `f` finds no field of, where Julia's getfield
# raises before it reads: get_checked_fieldindex (julia/src/builtins.c:994) checks the field against the value's
# own type, a position past its field count raising BoundsError of the value and the position (:1006
# jl_bounds_error), a name jl_field_index does not find (julia/src/datatype.c:1781: the type's field names, a
# NamedTuple's its names parameter, a tuple's its positions, so a tuple held as its record holds no name) raising
# FieldError of the type and the name (julia/src/rtutils.c:169 jl_has_no_field_error). The one answer of which
# classes raise: visitInstanceGet tests the receiver's class id against theirs before its selector call
# (formal(dev/formal/MCFieldSelectorTableSiteCheck.tla) SiteCheckTraps), and the selector admits the rest
# (field_selector_calls)
@quarantine pin"julia/src/builtins.c:994 get_checked_fieldindex" "Julia's getfield checks the field against the receiver's own type before it reads, raising BoundsError past its field count and FieldError for a name it lacks" Base.filter function classes_without_field(admitted::Vector{DataType}, @nospecialize(f), at::String)::Vector{DataType}
    f isa Int && return filter(c -> field_at_position(c, f, at) === nothing, admitted)
    f isa Symbol && return filter(c -> tuple_record_arity(c) !== nothing || Base.fieldindex(c, f, false) == 0, admitted)
    return DataType[]
end

# setfield!'s memory order, its operand `o` (nothing where the call has none, jl_f_setfield's notatomic default,
# julia/src/builtins.c:1059): a constant Symbol read as jl_get_atomic_order reads a store's (:967, storing):
# :not_atomic plain, :unordered, :monotonic, :release and :sequentially_consistent atomic, any other invalid
# (jl_get_atomic_order_checked's "invalid atomic ordering", :990); nothing where only run time knows it (the
# operand's JL_TYPECHK, :1061)
@quarantine pin"julia/src/builtins.c:967 jl_get_atomic_order" "Julia reads setfield!'s memory order from its Symbol at run time; a constant one is read here, once, for every write" Core.Symbol function setfield_order(o::Union{Nothing,NirValue})::Union{Symbol,Nothing}
    o === nothing && return :notatomic
    o isa NirConst && o.c.val isa Symbol || return nothing
    local s = o.c.val::Symbol
    return s === :not_atomic ? :notatomic : s in (:unordered, :monotonic, :release, :sequentially_consistent) ? :atomic : :invalid
end

# setfield!'s raise of a class holding no field of its key `key`, the raise a getfield of it makes too
# (classes_without_field): BoundsError of the value and the position past its fields, FieldError of its type and
# a name it lacks; one arm of SetfieldRaise
@quarantine pin"julia/src/builtins.c:994 get_checked_fieldindex" "Julia's setfield! finds the field by the key, a position or a name, as getfield does" Core.Symbol struct SetfieldNoField
    key::Union{Int,Symbol}
end
# setfield!'s raise whose message Julia's runtime spells: jl_errorf's ErrorException (a Module, an immutable struct,
# a const field) or, `atomic`, jl_atomic_error's ConcurrencyViolationError; one arm of SetfieldRaise
@quarantine pin"julia/src/builtins.c:994 get_checked_fieldindex" "Julia's setfield! raises its mutability's and its const field's ErrorException and its atomic check's ConcurrencyViolationError with a message of its own" Core.String struct SetfieldMessage
    msg::String
    atomic::Bool
end

"""
    SetfieldRaise

What a setfield! raises on a value of one class before it writes, Julia's checks in jl_f_setfield's order
(julia/src/builtins.c:1057): `SetfieldNoField` (the key finds no field) or `SetfieldMessage` (the receiver
or the field takes no write). Closed by its type: a `@closed` `Union` of two concrete structs that subtype
nothing; `setfield_raise` answers it and visitInstanceSet's site check matches it `@exhaustive`.

precedent(rust: enum + exhaustive match; dart: sealed class + exhaustive switch). Julia's differs: a
`Union` of concrete structs, its exhaustiveness checked when the package loads.
"""
@quarantine pin"julia/src/builtins.c:1057 jl_f_setfield" "a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const SetfieldRaise = Union{SetfieldNoField, SetfieldMessage}

# what a setfield! by the constant key `f` with the memory order `order` (setfield_order, valid) raises on a value
# of the class `c` before it writes, or nothing where it writes: Julia's checks in their order, jl_f_setfield's
# get_checked_fieldindex (julia/src/builtins.c:994), with `mutabl`: a Module ("cannot assign variables in other
# modules", :998), an immutable struct whatever the key (:1000, its type's name, a tuple held as its record a
# Tuple's), the key finding no field (classes_without_field: :1006 jl_bounds_error, :1010 jl_field_index's
# FieldError), a const field (:1018); then jl_f_setfield's atomic check (:1068-1071). The type check of the
# value follows (:1072). The one answer of which classes raise at a setfield!'s site: visitInstanceSet tests the
# receiver's class id against theirs before its selector call (formal(dev/formal/MCFieldSelectorTableSetCheck.tla)
# SetCheckTraps), and the setter selector admits the rest (field_selector_calls)
@quarantine pin"julia/src/builtins.c:1057 jl_f_setfield" "Julia's setfield! checks the receiver's own type before it writes, its mutability first, then the field, its constness and its atomicity" Base.ismutabletype function setfield_raise(c::DataType, f::Union{Int,Symbol}, order::Symbol, at::String)::Union{SetfieldRaise,Nothing}
    c === Module && return SetfieldMessage("cannot assign variables in other modules", false)
    local record = tuple_record_arity(c) !== nothing
    local name = record ? :Tuple : c.name.name
    !record && ismutabletype(c) || return SetfieldMessage("setfield!: immutable struct of type $name cannot be changed", false)
    isempty(classes_without_field(DataType[c], f, at)) || return SetfieldNoField(f)
    local idx = f isa Int ? f : Base.fieldindex(c, f, false)
    isconst(c, idx) && return SetfieldMessage("setfield!: const field .$(fieldname(c, idx)) of type $name cannot be changed", false)
    Base.isfieldatomic(c, idx) == (order === :notatomic) &&
        return SetfieldMessage(order === :notatomic ? "setfield!: atomic field cannot be written non-atomically" : "setfield!: non-atomic field cannot be written atomically", true)
    return nothing
end

# the field selector a field access names on receivers of the classes `admitted`: a name, its own; a
# position, the field each class holds there, as Julia's getfield reads it (fieldname(typeof(x), i), a
# record's own field for a tuple held as one). The selectors are named by their fields
# (DispatchTable.build), so a position naming one field in every admitted class that holds it is that
# field's selector; a class it reaches past its fields raises Julia's BoundsError at the site
# (classes_without_field), never through the selector; a position naming different fields in different
# classes is no one named selector, a located rejection
@quarantine pin"julia/src/builtins.c:994 get_checked_fieldindex" "Julia's getfield reads a position or a name as one field index of the receiver's own type (julia/src/builtins.c:994 get_checked_fieldindex), one name for the classes holding the field" Base.only function field_selector_name(@nospecialize(f), admitted::Vector{DataType})::String
    local at = "src/julia/classes.jl field_selector_name"
    f isa Symbol && return string(f)
    local names = String[]
    for c in admitted
        local n = field_at_position(c, f, at)
        n === nothing || n in names || push!(names, n)
    end
    length(names) <= 1 || reject!(Unquarantined("$at: a field access at position $f names the fields $(join(names, ", ")) in the classes its receiver admits, a selector per position not yet written"), at)
    return isempty(names) ? string(f) : only(names)
end

"""
Julia's answer where dart reads TFA's selector metadata: the calls of each field selector. A
`Core.getfield(x, f)` or `Core.setfield!(x, f, v)` whose receiver's type Julia's inference left
abstract (no concrete type, or a Union) and whose field `f` is a constant (a name or a position) is a
dynamic call of the getter or setter selector `f` names (`field_selector_name`), dart's instance field access through the
dispatch table. Each selector, a `FieldSelectorCalls` of its name and kind, in the order the closed world first meets it,
maps to its call count and the classes its receivers' types admit, `admitted(receiver)`, the
classes the receiver holds (field_receiver_classes: its concrete classes as
ClassIdNumbering.getConcreteClassIdRange reads them, the one reading, src/class_info.jl, a tuple as its
record), which DispatchTable.build passes, less those raising Julia's error at the site: a read's, those
holding no field of its name or position (classes_without_field, FieldError or BoundsError); a write's,
those jl_f_setfield refuses before it writes (setfield_raise). DispatchTable.build (src/dispatch_table.jl)
reads it where dart reads TFA's selector ids. A receiver of a concrete type is a direct access, no call of a selector.
"""
@quarantine pin"pkg/vm/lib/transformations/type_flow/table_selector_assigner.dart:142 TableSelectorAssigner.registerGetterCall" "a field access on a receiver Julia's inference left abstract is dart's dynamic call through the dispatch table, which TFA registers when the call is not direct (pkg/vm/lib/transformations/type_flow/table_selector_assigner.dart:142 TableSelectorAssigner.registerGetterCall)" Core.getfield function field_selector_calls(world::NirWorld, admitted_classes::Function)::Vector{FieldSelectorCalls}
    local out = FieldSelectorCalls[]
    for b in world, (index, st) in enumerate(b.stmts)
        st isa NirCall || continue
        local f = nir_callee(st)
        (f === Core.getfield || f === Core.setfield!) || continue
        length(st.args) >= 3 || continue
        local receiver = nir_value_type(b, st.args[2])
        isconcretetype(receiver) && continue
        # a tuple of no one shape (a concrete tuple never reaches here) is dart's record of a static type
        # Record or above, which dart reads by DynamicGet (code_generator.dart:2317 visitDynamicGet), its
        # dynamic dispatcher switching over the record classes holding the field (their `$1` fields,
        # record_class_generator.dart:23), never a call through the dispatch table. Julia's differs: the
        # intrinsifier writes that class-id switch at the read (intrinsics.jl), not in a shared dispatcher
        receiver <: Tuple && continue
        local name_op = st.args[3]
        name_op isa NirConst && (name_op.c.val isa Symbol || name_op.c.val isa Int) || continue
        local admitted = admitted_classes(receiver)::Vector{DataType}
        local is_setter = f === Core.setfield!
        # a class whose read or write raises before it reaches the field raises Julia's error at the site, so the
        # selector admits only the rest: a getter's, a class holding no field of the name or position
        # (classes_without_field: FieldError or BoundsError); a setter's, a class jl_f_setfield refuses before it
        # writes, its mutability first (setfield_raise). A write of an order only run time knows rejects at its
        # site and an invalid order raises there before any class's check: no call of the selector
        local at = "src/julia/classes.jl field_selector_calls"
        local order = is_setter ? setfield_order(length(st.args) >= 5 ? st.args[5] : nothing) : :notatomic
        (order === nothing || order === :invalid) && continue
        local raising = is_setter ? filter(c -> setfield_raise(c, name_op.c.val, order, at) !== nothing, admitted) :
                                    classes_without_field(admitted, name_op.c.val, at)
        admitted = filter(c -> !(c in raising), admitted)
        local name = field_selector_name(name_op.c.val, admitted)
        # a getter selector reads its field in every class it admits (ImplicitFieldAccessorCodeGenerator):
        # a field WasmTarget holds in another form than Julia's rejects at this site, as _directGet's read
        # rejects (memoryref_address_unread), never the selector's getter reading it as Julia's value
        # a MemoryRef's ptr_or_offset on a union of reference classes is read by its own class switch at the
        # read (src/intrinsics.jl memoryref_union_address), no selector
        is_setter || memoryref_union_classes(receiver, name_op.c.val) === nothing || continue
        is_setter || for c in admitted
            c <: Core.GenericMemoryRef || continue      # memoryref_address_unread's one class
            local fs = class_instance_fields(c, "src/julia/classes.jl field_selector_calls")
            local k = findfirst(x -> x.name == name, fs)
            local unread = k === nothing ? nothing : memoryref_address_unread(fs[k])
            unread === nothing || reject!(unread, "$(b.ci.def) statement $index")
        end
        # a field whose type Julia's inference reads as another than the one it holds rejects at a getter's or a
        # setter's site, as _directGet and _directSet do (declared_type_unheld)
        for c in admitted
            isconcretetype(c) && isstructtype(c) || continue
            local unheld = declared_type_unheld(c, Base.fieldindex(c, Symbol(name), false))
            unheld === nothing || reject!(unheld, "$(b.ci.def) statement $index")
        end
        local k = findfirst(e -> e.name == name && e.is_setter == is_setter, out)
        k === nothing && (push!(out, FieldSelectorCalls(name, is_setter, 0, DataType[], FieldAccessSite[])); k = length(out))
        out[k].call_count += 1
        push!(out[k].sites, FieldAccessSite(b.ci.def, index))
        for c in admitted
            c in out[k].classes || push!(out[k].classes, c)
        end
    end
    return out
end

"""
    CompileStatics()

The state dart2wasm keeps in statics, one compile's here (spec v16 X5, X8): `next_global_id`, dart's static
_ConstantAccessor._nextGlobalId (constants.dart:2234), the count behind each constant's `C<id>` name; and the memories
a compile's constants emit in part (_array_live_ref: each original Memory's live copy and the extent its Array defines)
or whole, so one Memory is never both (_live_memory's rule, which dart has no counterpart of); and the image's ids
(src/julia/runtime/hashing.jl image_slot!): whether the program reads an object's identity slot, decided once, each id
the compiling process gave a constant whose identity it reads, IMAGE_IDS's entries in order, and whether the table was
made, after which no constant joins it; and the module binding table (src/julia/runtime/bindings.jl
module_binding_answers): its function, defined at the first call, and whether its body was made, after which no Module
or Symbol constant is made. Held by the compile's one
_ConstantAccessor (Constants._constantAccessor, late: one a compile), the class whose static dart declares, and read
through it as dart reads a static through its class, so the Translator's fields stay exactly dart's. Julia differs:
dart2wasm compiles one program a process, so a static is that program's; Julia compiles many a process (a test file,
the climb's compiling process), so a compile's state lives in the object doing the compile, as Julia's own compiler
keeps an inference session's results in its NativeInterpreter (inf_cache), never in a module global.
"""
@quarantine pin"precedent(julia: Compiler/src/types.jl:380 NativeInterpreter)" "a compile's state is held by the object doing the compile, as Julia's NativeInterpreter holds its session's inf_cache, never a global" Base.IdSet struct CompileStatics
    next_global_id::Base.RefValue{Int}
    live_memories::IdDict{GenericMemory,Tuple{GenericMemory,UnitRange{Int}}}
    whole_memories::Base.IdSet{GenericMemory}
    reads_identity::Base.RefValue{Union{Nothing,Bool}}
    image_ids::Vector{Int64}
    image_ids_made::Base.RefValue{Bool}
    binding_table::Base.RefValue{Any}
    binding_table_made::Base.RefValue{Bool}
    CompileStatics() = new(Ref(0), IdDict{GenericMemory,Tuple{GenericMemory,UnitRange{Int}}}(), Base.IdSet{GenericMemory}(),
                           Ref{Union{Nothing,Bool}}(nothing), Int64[], Ref(false), Ref{Any}(nothing), Ref(false))
end

"""
    _live_memory(m, live, what, at) -> Memory

A constant's memory `m` as its owner defines it (spec v16 X5), the one rule every owner's memory goes through: each
element `live(i)` marks holds its element; every other holds no defined element, so it is #undef (a boxed element type:
the null), the all-zero bits (an isbits one), the value a zeroed allocation holds (an isbits union, which Julia always
allocates zeroed: its selector-0 type at all-zero bytes) or a singleton's one value (a type that stores no bytes), never
the bytes Julia left there (host heap bytes, a popped or deleted element's, addresses among them, different in each
process: a module would carry process state). An isbits element type whose zero bits are no value of it (one with
padding) is refused, located, when an element is not live. The owners, each one function: a Dict's keys and vals, the slots
`isslotfilled` marks (_dict_live_memory); an Array's memory, its size's elements from its ref's offset
(_array_live_memory); a Set, its Dict's; a Memory reached bare, through a MemoryRef or in any other struct's field, its
own owner: every element (src/constants.jl's Memory branch, which refuses one Memory both whole and in part). Julia
differs: its image writer (src/staticdata.c jl_write_values) copies an isbits memory's bytes as they are, resetting only
Ptr elements to C_NULL.
"""
@quarantine pin"precedent(julia: base/genericmemory.jl:78 _unsetindex!)" "an element its owner leaves undefined holds no value of Julia's (_unsetindex! leaves an isbits element's bytes as they were), so it is emitted as no value, never as those bytes" Base.isbitsunion function _live_memory(m::Memory{T}, live, what::String, at::String)::Memory{T} where {T}
    local out = Memory{T}(undef, length(m))
    if !all(live, eachindex(m))
        if isbitstype(T) && Base.issingletontype(T)
            fill!(out, T.instance)   # a singleton's one value, its element in every slot (a Set's Dict{T,Nothing})
        elseif isbitstype(T)
            local z = try
                only(reinterpret(T, zeros(UInt8, sizeof(T))))
            catch e
                reject!(ProgramError("$at: $what whose element type $T has no all-zero value ($(sprint(showerror, e))): its undefined elements have no value to emit; build it in the function"), at)
            end
            fill!(out, z)
        elseif Base.isbitsunion(T)
            # Julia allocates an isbits union's memory zeroed (datatype.c:551 jl_get_genericmemory_layout's zi = 1,
            # genericmemory.c:71 _new_genericmemory_'s memset), its data and selector bytes alike: an element no
            # write defined reads as Julia's own value there, the union's selector-0 type at all-zero bytes, which
            # `out`, allocated so, already holds in every slot; the flag read is julia.h:619's zeroinit, bit 0x0010 of
            # a DataType's flags, as runtime_internals.jl:836 isbitstype reads bit 0x0008
            (Memory{T}.flags & 0x0010) == 0x0010 ||
                reject!(Internal("$at: $what whose element type $T is an isbits union Julia does not allocate zeroed"), at)
        end
    end
    for i in eachindex(m)
        live(i) && isassigned(m, i) && (out[i] = m[i])
    end
    return out
end
"""
    _dict_live_memory(d, m, at) -> Memory

A Dict constant's `keys` or `vals` memory `m` as Julia defines it (spec v15 W3): each slot `Base.isslotfilled` marks
(base/dict.jl:134, the slot byte's high bit, the one record of which elements are live; Julia's own serializer writes
a Dict as those slots' pairs alone, Serialization's serialize_dict_data) holds its element, every other none
(_live_memory). A Set is its Dict.
"""
@quarantine pin"precedent(julia: base/dict.jl:682 skip_deleted)" "a Dict's live elements are the slots isslotfilled marks (dict.jl:134), the ones Julia's own iteration visits (skip_deleted) and its serializer writes" Base.isslotfilled function _dict_live_memory(d::Dict, m::Memory{T}, at::String)::Memory{T} where {T}
    return _live_memory(m, i -> Base.isslotfilled(d, i), "a Dict constant", at)
end
"""
    _array_live_memory(a, at) -> (Memory, live extent)

An Array constant's memory as Julia defines it (spec v16 X5): its `size`'s elements (array.jl:194), from its ref's
offset (memoryrefoffset) on, hold theirs; the rest of the memory holds none (_live_memory): a capacity tail `sizehint!`
reserved, or the bytes `pop!`/`_deleteend!` (array.jl:1226) leave as they were for an isbits element.
"""
@quarantine pin"precedent(julia: base/array.jl:1226 _deleteend!)" "an Array's value is its size's elements from its ref's offset; _deleteend! leaves the elements past them undefined (an isbits element's bytes as they were)" Base.memoryrefoffset function _array_live_memory(a::Array, at::String)
    local ref = getfield(a, :ref)
    local live = Base.memoryrefoffset(ref):(Base.memoryrefoffset(ref) + length(a) - 1)
    return (_live_memory(ref.mem, in(live), "an Array constant", at), live)
end
"""
    _array_live_ref(statics, a, at) -> MemoryRef

An Array constant's `ref` field as the module holds it (spec v16 X5): its ref unchanged when its size covers its whole
memory; else a ref, at the same offset, into its memory's live copy (_array_live_memory), one copy a Memory a compile
(statics.live_memories, CompileStatics), so two Arrays sharing a Memory share its copy. A Memory two Arrays define differently, or one
held both whole and by an Array that defines part of it, is refused, located: one constant cannot hold both.
"""
@quarantine pin"precedent(julia: base/array.jl:1226 _deleteend!)" "an Array's value is its size's elements from its ref's offset, the module's ref points into a memory holding exactly those" Base.memoryrefoffset function _array_live_ref(statics::CompileStatics, a::Array, at::String)
    local ref = getfield(a, :ref)
    local m, off = ref.mem, Base.memoryrefoffset(ref)
    local live = off:(off + length(a) - 1)
    live == eachindex(m) && return ref   # every element of its memory is the Array's: nothing to leave out
    m in statics.whole_memories &&
        reject!(ProgramError("$at: a Memory constant held whole and by an Array that defines part of it (its size): one constant cannot hold both; build the Array in the function"), at)
    local seen = get!(() -> _array_live_memory(a, at), statics.live_memories, m)
    seen[2] == live || reject!(ProgramError("$at: a Memory held by two Array constants of different sizes ($(seen[2]) and $live of it): one constant cannot hold each one's elements; build the Arrays in the function"), at)
    return Core.memoryrefnew(Core.memoryrefnew(seen[1]), off, false)
end

# an Array's `ref` and a Dict's `keys` and `vals`, as MEMORY_OWNERS dispatches them: the memory each defines, recorded
# under the ORIGINAL Memory as defined by its owner (statics.live_memories, the memory itself its own live copy when its
# owner leaves nothing out), so one Julia Memory is one module object by every path to it (dev/formal/ObjectIdentity.tla
# WriteSeenSameConstant)
@quarantine pin"precedent(julia: base/array.jl:194 size)" "an Array's whole memory is its size's elements when its size covers it, its owner's definition of each element" Base.eachindex function _array_owned(statics::CompileStatics, a::Array, at::String)
    local ref = _array_live_ref(statics, a, at)
    ref.mem === getfield(a, :ref).mem && get!(statics.live_memories, ref.mem, (ref.mem, eachindex(ref.mem)))
    return ref
end
@quarantine pin"precedent(julia: base/dict.jl:682 skip_deleted)" "a Dict's keys and vals are its filled slots' elements, its owner's definition of each" Base.eachindex function _dict_owned(statics::CompileStatics, d::Dict, name::String, at::String)
    local m = getfield(d, Symbol(name))
    local seen = get(statics.live_memories, m, nothing)
    seen === nothing || return seen[1]   # the Memory met before, by another path: its one module object
    local copy = _dict_live_memory(d, m, at)
    # _array_live_ref's rule: where the live copy leaves nothing out (each slot the Dict does not fill already holds no
    # value: a boxed element's #undef, a singleton's one value, as Base's _delete! and empty! leave a boxed slot), the
    # Memory itself is the module object, so a second path to it (getfield(d, :vals) held as a constant of its own)
    # reaches the same object. A non-isbits Memory with a value in a slot the Dict does not fill (one written through
    # getfield(d, :vals)) differs from its copy; an isbits one never reaches here held whole (_unowned_memory refuses it)
    if all(i -> isassigned(copy, i) == isassigned(m, i) && (!isassigned(m, i) || copy[i] === m[i]), eachindex(m))
        statics.live_memories[m] = (m, eachindex(m))
        return m
    end
    # else the copy differs from the Memory: one constant cannot be both. Held whole before (src/constants.jl's Memory
    # branch), it is refused here; met after this, the Memory branch refuses it
    m in statics.whole_memories &&
        reject!(ProgramError("$at: a Memory constant held whole and by a Dict that defines part of it (its filled slots): one constant cannot hold both; build the Dict in the function"), at)
    statics.live_memories[m] = (copy, eachindex(m))
    return copy
end
"""
    memory_constant_object(statics, m) -> GenericMemory

The Julia Memory a Memory constant `m` stands for: the original whose live copy `m` is (the one record of copies,
statics.live_memories, original => (copy, live extent), written by MEMORY_OWNERS' functions), else `m` itself. A
constant stands for the object the program reaches, never the copy the compiler makes of it, so the constant's key
(ConstantOwner) and its image id (src/julia/runtime/hashing.jl image_slot!) name the original
(dev/formal/ConstantImageIds.tla: CopyOwnKey is the key naming the copy).

precedent(julia: src/staticdata.c:1105 jl_queue_for_serialization_, which keys each object by its own address: the
image holds the object itself, so its id is that object's). Julia differs from dart: dart's constants are values,
never copies of an object.
"""
@quarantine pin"precedent(julia: src/staticdata.c:1105 jl_queue_for_serialization_)" "a constant stands for the Julia object the program reaches; a live copy the compiler makes of a Memory stands for the original" Core.GenericMemory function memory_constant_object(statics::CompileStatics, m::GenericMemory)::GenericMemory
    for (original, (copy, _)) in statics.live_memories
        copy === m && return original
    end
    return m
end
# a Dict's `slots`: every byte is the Dict's (its constructor, rehash! and empty! fill the memory with 0x0, then each
# slot's byte marks it empty, filled or deleted), so the memory is held whole, its owner defining each element
@quarantine pin"precedent(julia: base/dict.jl:220 empty!)" "a Dict's slots are each a byte its Dict wrote: empty! and the constructor fill them with 0x0, a set slot's byte marks it" Base.eachindex function _dict_slots_owned(statics::CompileStatics, d::Dict, name::String, at::String)
    local m = getfield(d, :slots)
    get!(statics.live_memories, m, (m, eachindex(m)))
    return m
end
"""
    MEMORY_OWNERS

The owners of a constant's memory (spec v17 Y6), the one table: each a type, a field of it whose memory it defines,
and the function that gives that memory with its live elements alone, each pinned to Julia's own definition (an
Array's size from its ref's offset, _array_owned; a Dict's filled slots, _dict_owned, and its `slots` bytes, every
one its Dict's, _dict_slots_owned; a Set is its Dict). A constant
reaches an isbits memory through no owner here (a bare Memory{T}(undef, n), IOBuffer's `data`, a MemoryRef, any other
struct's field) only as a refusal, located (_unowned_memory): Julia records nowhere which of its elements a write
defined, so its bytes are no value to emit. A boxed element type keeps #undef as the null. Julia differs: its image
writer (src/staticdata.c jl_write_values) copies such bytes as they are.
"""
@quarantine pin"precedent(julia: base/array.jl:194 size)" "a memory's live elements are its owner's to define; Julia keeps no other record of them" Base.Dict const MEMORY_OWNERS =
    ((Array, "ref", (s, v, f, at) -> _array_owned(s, v, at)), (Dict, "keys", _dict_owned), (Dict, "vals", _dict_owned),
     (Dict, "slots", _dict_slots_owned))
"""    memory_owner(v, name) -> the owner's function, or nothing (MEMORY_OWNERS)"""
@quarantine pin"precedent(julia: base/array.jl:194 size)" "MEMORY_OWNERS read: the owner of a constant's field, the one dispatch" Core.isa function memory_owner(v, name::String)
    for (T, f, g) in MEMORY_OWNERS
        v isa T && name == f && return g
    end
    return nothing
end
"""    _unowned_memory(m, at)

A memory a constant holds whole, refused when its elements are isbits bytes no owner defines (MEMORY_OWNERS), located;
an empty one, or one of a singleton or boxed element type (#undef the null), is held whole."""
@quarantine pin"precedent(julia: base/genericmemory.jl:78 _unsetindex!)" "an isbits memory's undefined elements are bytes no write defined, which Julia records nowhere outside an owner" Base.isbitsunion function _unowned_memory(m::GenericMemory{K,T}, at::String) where {K,T}
    isempty(m) && return nothing
    (isbitstype(T) && !Base.issingletontype(T) || Base.isbitsunion(T)) &&
        reject!(ProgramError("$at: an isbits Memory{$T} constant reached through no owner MEMORY_OWNERS lists (a bare Memory, a MemoryRef, IOBuffer's data, another struct's field): Julia records nowhere which of its elements a write defined, so its bytes are no value to emit; build it in the function, or hold it in an Array"), at)
    return nothing
end
