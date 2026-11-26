# Julia's module-binding queries at run time: jl_is_const (julia/src/module.c:1800), jl_is_binding_deprecated (:1853) and
# jl_boundp (:1468, Julia's isdefinedglobal builtin, julia/src/builtins.c:1353 jl_f_isdefinedglobal), each Julia's answer
# for a (module, name) pair at the program's world. Julia's image keeps each module's bindings, pruned to what the image
# reaches (julia/src/staticdata.c:2694 jl_prune_module_bindings), and its runtime answers a query from the module it
# holds. A WasmTarget module holds no Module's bindings; its closed world has one world, so a pair's answers are fixed:
# the module binding table, one function made after every body is compiled (module_binding_answers), answers each pair
# of every Module constant by every Symbol constant the module holds with the facts the compiling process reads at the
# program's world (src/julia/nir.jl _binding_at, the one reader of a binding's facts), and a pair outside it ends the
# program at the fatal arm, located, never "no binding" (D9: native Julia answers from the whole module). dart has no
# counterpart: a dart program reflects on no top-level binding at run time.

# the answers' bits: a pair's jl_is_const, jl_is_binding_deprecated and jl_boundp(m, s, 1) (isdefinedglobal)
@quarantine pin"julia/src/module.c:1800 jl_is_const" "a pair's jl_is_const answer, one bit of the module binding table's" Core.UInt32 const BINDING_IS_CONST = UInt32(1)
@quarantine pin"julia/src/module.c:1853 jl_is_binding_deprecated" "a pair's jl_is_binding_deprecated answer, one bit of the module binding table's" Core.UInt32 const BINDING_DEPRECATED = UInt32(2)
@quarantine pin"julia/src/module.c:1468 jl_boundp" "a pair's jl_boundp(m, s, 1) answer, Julia's isdefinedglobal, one bit of the module binding table's" Core.UInt32 const BINDING_DEFINED = UInt32(4)

"""
    binding_answers(b) -> UInt32

A binding's answers as the module binding table holds them, its facts at the program's world (NirBinding: `constant`,
`deprecated`, `defined`), each one bit.
"""
@quarantine pin"julia/src/module.c:1800 jl_is_const" "the facts the compiling process reads for a pair at the program's world (NirBinding), each query's answer a bit" Core.UInt32 binding_answers(b)::UInt32 =
    (b.constant ? BINDING_IS_CONST : 0x00000000) | (b.deprecated ? BINDING_DEPRECATED : 0x00000000) | (b.defined ? BINDING_DEFINED : 0x00000000)

"""
    module_binding_answers(m, s) -> UInt32

The answers of Julia's binding queries for the pair (m, s), the module binding table's entry (binding_answers' bits).
The intrinsifier lowers a call to a call of the table's one function, made once every constant is (src/intrinsics.jl),
and a pair outside the table to the fatal arm; natively no table exists, so the body raises.
"""
@quarantine pin"julia/src/staticdata.c:2694 jl_prune_module_bindings" "Julia's image keeps a module's bindings, pruned to what it reaches, and its runtime answers a query from them; a WasmTarget module holds the answers of each pair of its Module and Symbol constants at the program's world in one function" Core.UInt32 @noinline module_binding_answers(m::Module, s::Symbol)::UInt32 =
    _wasm_only(UInt32)

@quarantine pin"julia/src/module.c:1800 jl_is_const" "Julia's runtime answers whether a binding is constant at the task's world; the closed world's one world answers it from the module binding table" Base.Cint jl_is_const(m::Module, s::Symbol)::Cint =
    Cint(module_binding_answers(m, s) & BINDING_IS_CONST != 0x00000000)

@quarantine pin"julia/src/module.c:1853 jl_is_binding_deprecated" "Julia's runtime answers whether a binding is deprecated at the task's world; the closed world's one world answers it from the module binding table" Base.Cint jl_is_binding_deprecated(m::Module, s::Symbol)::Cint =
    Cint(module_binding_answers(m, s) & BINDING_DEPRECATED != 0x00000000)

# Julia's isdefinedglobal(m, s), jl_f_isdefinedglobal's jl_boundp(m, s, 1) (julia/src/builtins.c:1353, :1383)
@quarantine pin"julia/src/builtins.c:1353 jl_f_isdefinedglobal" "Julia's isdefinedglobal builtin answers jl_boundp(m, s, 1) at the task's world; the closed world's one world answers it from the module binding table" Core.Bool jl_f_isdefinedglobal(m::Module, s::Symbol)::Bool =
    module_binding_answers(m, s) & BINDING_DEFINED != 0x00000000

"""
    module_binding_table(translator, at) -> FunctionBuilder

The module binding table's one function, `(Module, Symbol) -> i32`: defined at its first call, its body made by a linking
action once every body is compiled (_make_module_binding_table), as dart2wasm outputs its whole-program tables after code
generation and its linking actions (translator.dart:544-553).
"""
@quarantine pin"dart2wasm/lib/translator.dart:524 Translator.translate" "dart2wasm outputs its whole-program tables after code generation (dispatchTable.output(), translator.dart:550); the module binding table's body is made in a linking action once every body is compiled, its pairs the final constants" Base.push! function module_binding_table(t, at::String)
    local statics = t.constants[]._constant_accessor[].statics
    local made = statics.binding_table[]
    made === nothing || return made
    statics.binding_table_made[] && reject!(Internal("src/julia/runtime/bindings.jl module_binding_table: a call of the module binding table made after its body"), at)
    local inputs = WasmBuilder.IR.ValueType[WasmBuilder.with_nullability(Dart2Wasm.translate_type(t, Module), false),
                                            WasmBuilder.with_nullability(Dart2Wasm.translate_type(t, Symbol), false)]
    local fn = WasmBuilder.define(Dart2Wasm.main_module(t).functions[],
        WasmBuilder.define_function(Dart2Wasm.types_builder(t), inputs, WasmBuilder.IR.ValueType[WasmBuilder.IR.NumType_i32]), "module binding table")
    statics.binding_table[] = fn
    push!(t.linking_actions, () -> _make_module_binding_table(t, fn))
    return fn
end

"""
    _make_module_binding_table(translator, fn)

The table's body: for every Module constant and every Symbol constant the module holds (its constants once every body is
compiled, each order its full name's), the pair's answers at the program's world (binding_answers of
src/julia/nir.jl's _binding_at, the one reader of a binding's facts), compared by identity, as Julia's runtime looks a
binding up by its module and its interned name (julia/src/module.c:1524 jl_get_module_binding); -1 past every pair.
After it no Module or Symbol constant is made (ensureConstant refuses one, Internal).
formal(dev/formal/ModuleBindingTable.tla): Sound, Answered
"""
@quarantine pin"julia/src/module.c:1524 jl_get_module_binding" "Julia's runtime finds a binding by its module and interned name; the table compares the pair against each pair of the module's constants by identity" Core.GlobalRef function _make_module_binding_table(t, fn)::Nothing
    local statics = t.constants[]._constant_accessor[].statics
    statics.binding_table_made[] = true
    local consts = t.constants[]
    local vals = Any[k.c.val for k in keys(consts.constant_info) if k isa NirConst]
    local mods = sort!(Module[v for v in vals if v isa Module]; by = m -> join(fullname(m), "."))
    local syms = sort!(Symbol[v for v in vals if v isa Symbol]; by = String)
    local world = t.component.world
    local b = WasmBuilder.body(fn)
    local lm, ls = WasmBuilder.locals(fn)[1], WasmBuilder.locals(fn)[2]
    for m in mods
        WasmBuilder.local_get(b, lm)
        Dart2Wasm.instantiate_constant(consts, b, NirConst(Core.Const(m)), lm.type)
        WasmBuilder.ref_eq(b)
        WasmBuilder.if_(b)
        for s in syms
            WasmBuilder.local_get(b, ls)
            Dart2Wasm.instantiate_constant(consts, b, NirConst(Core.Const(s)), ls.type)
            WasmBuilder.ref_eq(b)
            WasmBuilder.if_(b)
            WasmBuilder.i32_const(b, Int(binding_answers(_binding_at(world, GlobalRef(m, s)))))
            WasmBuilder.return_(b)
            WasmBuilder.var"end"(b)
        end
        WasmBuilder.var"end"(b)
    end
    WasmBuilder.i32_const(b, -1)
    WasmBuilder.var"end"(b)
    return nothing
end
