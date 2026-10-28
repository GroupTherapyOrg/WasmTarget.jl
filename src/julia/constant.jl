# A constant of the program (dev/MARCH.md 1.C): dart's Kernel `Constant`, the value a constant
# expression evaluated to, is a Julia value in typed IR (a literal, a QuoteNode's payload, a const
# binding's value, a value Julia's inference folded), as Julia's own `Core.Const` lattice element holds
# it. Each Kernel kind dart2wasm visits is a mirror of one form of Julia value, holding that Const, so
# two constants are one exactly when Julia calls their values egal (`===`): Kernel canonicalizes its
# constants, and a Dict keyed by a mirror canonicalizes by Julia's identity. The kind is read once from
# the value's form (`julia_constant`); a form no kind holds rejects, located, never a guess.

"""`nothing`, the one value of `Nothing`: Kernel's `NullConstant`."""
@quarantine "Julia's null is nothing, the singleton of Nothing; Kernel has a NullConstant" Core.Const struct NullConstant
    c::Core.Const
end
"""A `Bool`: Kernel's `BoolConstant`."""
@quarantine "Julia's Bool constant, as Core.Const holds it" Core.Const struct BoolConstant
    c::Core.Const
end
"""An integer of a primitive type with a wasm representation (the 8- to 64-bit integers, `Char`):
Kernel's `IntConstant`; the value keeps its Julia type, whose bits it is."""
@quarantine "Julia's integers are many primitive types, each its own class; Kernel has one IntConstant" Core.Const struct IntConstant
    c::Core.Const
end
"""A `Float32` or `Float64`: Kernel's `DoubleConstant`; the value keeps its Julia type."""
@quarantine "Julia's floats are two primitive types with a wasm representation; Kernel has one DoubleConstant" Core.Const struct DoubleConstant
    c::Core.Const
end
"""A `String`: Kernel's `StringConstant`."""
@quarantine "Julia's String constant, as Core.Const holds it" Core.Const struct StringConstant
    c::Core.Const
end
"""A `Symbol`: Kernel's `SymbolConstant`."""
@quarantine "Julia's Symbol constant, interned by Julia" Core.Const struct SymbolConstant
    c::Core.Const
end
"""A `Tuple` or `NamedTuple`: Kernel's `RecordConstant`, positional and named fields."""
@quarantine "Julia's tuples are its records, positional (Tuple) or named (NamedTuple)" Core.Const struct RecordConstant
    c::Core.Const
end
"""A type as a value (`DataType`, `UnionAll`, `Union`, `Union{}`): Kernel's `TypeLiteralConstant`."""
@quarantine "a type is a value in Julia, of one of its kinds" Core.Const struct TypeLiteralConstant
    c::Core.Const
end
"""
Any other object: an instance of a struct (a mutable one by its identity, as `===` compares it), a
function's singleton and a closure among them: Kernel's `InstanceConstant`, whose class is the
value's `typeof` and whose field values are its fields. Julia's functions are values of their own
singleton classes and its closures structs of their captures, so no tear-off kind is needed.
"""
@quarantine "Julia's objects are struct instances, its functions and closures among them" Core.Const struct InstanceConstant
    c::Core.Const
end
"""A constant of the compiler's own: Kernel's `AuxiliaryConstant`, dart2wasm's `DummyValueConstant`."""
@quarantine "Kernel's AuxiliaryConstant is the backend's own constant kind, a value of WasmTarget's" Core.Const struct AuxiliaryConstant
    c::Core.Const
end

"""
    Constant

A constant of the program: one kind per form of Julia value dart2wasm's constant visitors distinguish.
A closed sum by construction, `@closed`, and `constant_form` its `@exhaustive` match, checked when the
package loads (`construction_check(::Val{:Constant})`).

precedent(dart: Kernel's Constant hierarchy, visited by ConstantVisitor; rust: enum + exhaustive
match). Julia's differs: a constant is any value, so the kind is read once from the value's form and
each kind holds Julia's own `Core.Const`.
"""
@quarantine "a closed sum is a Union in Julia, which has no sealed classes or enums" Core.Union @closed const Constant = Union{
    NullConstant, BoolConstant, IntConstant, DoubleConstant, StringConstant, SymbolConstant,
    RecordConstant, TypeLiteralConstant, InstanceConstant, AuxiliaryConstant}

# a constant's kind, one arm per kind (Kernel's Constant.accept, which visits by kind)
@quarantine "the constant sum's one match, an exhaustive switch where Kernel's visitor dispatches by class" Core.String function constant_form(c::Constant)::String
    @exhaustive c::Constant begin
        NullConstant => "null"
        BoolConstant => "bool"
        IntConstant => "int"
        DoubleConstant => "double"
        StringConstant => "string"
        SymbolConstant => "symbol"
        RecordConstant => "record"
        TypeLiteralConstant => "type"
        InstanceConstant => "instance"
        AuxiliaryConstant => "auxiliary"
    end
end

"""
    julia_constant(c::Core.Const, at) -> Constant

The kind of the constant `c` holds, from its value's form: `nothing`, a `Bool`, a wasm integer or
float, a `String`, a `Symbol`, a tuple, a type, or another object; `auxiliary` marks a value of
WasmTarget's own (dart2wasm's DummyValueConstant). An object whose data Julia holds outside its fields
(an `Array`, a `Memory`) and a primitive value with no wasm representation (`Float16`, `Int128`, a
`Ptr`) reject, located, until their representation is written.
"""
@quarantine "a constant's kind is read from its value's form, Julia's typeof and its kinds" Base.isprimitivetype function julia_constant(c::Core.Const, at::String; auxiliary::Bool = false)::Constant
    local v = c.val
    auxiliary && return AuxiliaryConstant(c)
    v === nothing && return NullConstant(c)
    v isa Bool && return BoolConstant(c)
    # the integer types with a wasm representation (translator.dart's builtinTypes): every 8- to 64-bit
    # integer, and Char, whose bits are a 32-bit integer
    v isa Union{Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Char} && return IntConstant(c)
    v isa Union{Float32, Float64} && return DoubleConstant(c)
    v isa String && return StringConstant(c)
    v isa Symbol && return SymbolConstant(c)
    v isa Union{Tuple, NamedTuple} && return RecordConstant(c)
    v isa Type && return TypeLiteralConstant(c)
    local T = typeof(v)
    isprimitivetype(T) && reject!(Unquarantined("src/julia/constant.jl: a constant of the primitive type $T, with no wasm representation"), at)
    v isa Union{AbstractArray, Memory, Core.SimpleVector, Module} &&
        reject!(Unquarantined("src/julia/constant.jl: a constant $T, whose data Julia holds outside its fields"), at)
    return InstanceConstant(c)
end

# a sample of each mirror's Julia form, built by Julia's own constructors: converted at load, each must
# come back as the mirror that names its form (check_mirrors, src/julia/parity.jl)
# the samples' converter: a sample holding a Const stands for a value of WasmTarget's own
@quarantine "the mirror samples' converter, a Const in a Const marking the auxiliary sample" Core.Const _constant_sample(c::Core.Const, at::String)::Constant =
    julia_constant(c, at; auxiliary = c.val isa Core.Const)
mirror_samples!(_constant_sample, :Constant,
    NullConstant => Core.Const(nothing), BoolConstant => Core.Const(true), IntConstant => Core.Const(Int32(7)),
    DoubleConstant => Core.Const(1.5), StringConstant => Core.Const("s"), SymbolConstant => Core.Const(:s),
    RecordConstant => Core.Const((1, "a")), TypeLiteralConstant => Core.Const(Int64),
    InstanceConstant => Core.Const(1 // 2), AuxiliaryConstant => Core.Const(Core.Const(0)))

# the constant sum's assertion, run when the package loads
@quarantine "the constant sum's assertion, run when the package loads" Base.Val construction_check(::Val{:Constant})::Int = check_sum_matched(@__MODULE__, :Constant)
