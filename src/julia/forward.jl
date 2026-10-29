# The forward declarations the ported wasm_builder needs where its parts point back at their owner
# through concrete classes only: IR.Module, which every function, global, table, memory and tag
# names as its `enclosingModule` (module.dart:12, "the data structures are cyclic"); ModuleBuilder,
# which every part builder names (builder/module.dart:20, "cyclic dependencies"); and
# InstructionsBuilder, whose patch points name the builder of their patch (instructions.dart:4996).
# A cycle through a dart abstract class needs none: that class is the abstract type (BaseFunction,
# Global, DefType, …).

"""
    AbstractModule

The forward declaration of `WasmBuilder.IR.Module`, its one subtype: the type of a part's
`enclosing_module` field, declared before the parts so the Module that holds them can follow
(include_dart refuses two declarations that need each other).

precedent(c: a forward-declared struct, `struct Module;`; ocaml: a signature before its
implementation). Julia's differs: it has no forward declaration, so an abstract type stands for the
struct and its one subtype is checked by reflection when the package loads.
"""
@quarantine "Julia has no forward struct declaration; the IR's back-pointers to their Module name this abstract type" Core.DataType abstract type AbstractModule end

"""
    AbstractModuleBuilder

The forward declaration of `WasmBuilder.ModuleBuilder`, its one subtype, as `AbstractModule` is
IR.Module's: the type of a part builder's `moduleBuilder` field.

precedent(c: a forward-declared struct; ocaml: a signature before its implementation). Julia's
differs: it has no forward declaration, so an abstract type stands for the struct and its one
subtype is checked by reflection when the package loads.
"""
@quarantine "Julia has no forward struct declaration; the builders' back-pointers to their ModuleBuilder name this abstract type" Core.DataType abstract type AbstractModuleBuilder end

"""
    AbstractInstructionsBuilder

The forward declaration of `WasmBuilder.InstructionsBuilder`, its one subtype, as `AbstractModule` is
IR.Module's: the type of a patchable region's `patchBuilder`, which the builder's patch points hold.

precedent(c: a forward-declared struct; ocaml: a signature before its implementation). Julia's
differs: it has no forward declaration, so an abstract type stands for the struct and its one
subtype is checked by reflection when the package loads.
"""
@quarantine "Julia has no forward struct declaration; a patchable region's builder names this abstract type" Core.DataType abstract type AbstractInstructionsBuilder end

"""
    check_forward(forward, sole, mod) -> Int

A forward declaration's check: `sole` subtypes `forward`, and no other type does among those bound
in every module loaded when the package loads, Main and `mod` (the package, while it loads), with
their submodules; a parametric type is read through its UnionAll, so `X{T}` cannot
escape. Throws a `ConstructionViolation` naming the first other subtype.

precedent(julia: InteractiveUtils.subtypes, which reads every loaded module's bindings the same
way). Julia's differs from a forward-declared struct: an abstract type stays open to any module, so
the check reads them all where the package loads (A45S3).
"""
@quarantine "the forward declaration's one subtype, found by reflection over every loaded module's bindings" Base.loaded_modules_array function check_forward(forward::DataType, sole::DataType, mod::Module)::Int
    local roots = Module[Base.loaded_modules_array(); Main; mod]
    sole <: forward || throw(ConstructionViolation(string(nameof(forward)), "$sole does not subtype it"))
    local seen = Base.IdSet{Module}()
    local walk(m::Module) = begin
        m in seen && return
        push!(seen, m)
        for n in names(m; all = true)
            isdefined(m, n) || continue
            local b = getglobal(m, n)
            if b isa Module
                parentmodule(b) === m && b !== m && walk(b)
            else
                local t = b isa UnionAll ? Base.unwrap_unionall(b) : b
                t isa DataType && t !== forward && t.name !== sole.name && t <: forward &&
                    throw(ConstructionViolation(string(nameof(forward)), "$m.$n subtypes it, where $sole is its one subtype"))
            end
        end
    end
    foreach(walk, roots)
    return 0
end

# checked when every definition exists (src/WasmTarget.jl calls it after include_dart)
@quarantine "AbstractModule's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractModule})::Int = check_forward(AbstractModule, WasmBuilder.IR.Module, @__MODULE__)
@quarantine "AbstractModuleBuilder's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractModuleBuilder})::Int = check_forward(AbstractModuleBuilder, WasmBuilder.ModuleBuilder, @__MODULE__)
@quarantine "AbstractInstructionsBuilder's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractInstructionsBuilder})::Int = check_forward(AbstractInstructionsBuilder, WasmBuilder.InstructionsBuilder, @__MODULE__)

"""
    AbstractClosures

The forward declaration of `Dart2Wasm.Closures`, its one subtype: the type of a Lambda's
`enclosing_member_closures`, declared before Lambda so that Closures, which maps each function to
its Lambda, can follow (closures.dart:1327 and :1440 name each other).

precedent(c: a forward-declared struct; ocaml: a signature before its implementation). Julia's
differs: it has no forward declaration, so an abstract type stands for the struct and its one
subtype is checked by reflection when the package loads.
"""
@quarantine "Julia has no forward struct declaration; a Lambda's back-pointer to its Closures names this abstract type" Core.DataType abstract type AbstractClosures end

# checked when every definition exists (src/WasmTarget.jl calls it after include_dart)
@quarantine "AbstractClosures's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractClosures})::Int = check_forward(AbstractClosures, Dart2Wasm.Closures, @__MODULE__)

"""
    AbstractLambda

The forward declaration of `Dart2Wasm.Lambda`, its one subtype: the type of a LambdaCallTarget's
`_lambda`, declared before LambdaCallTarget so that Lambda, which holds its call target, can follow
(closures.dart:1327 and code_generator.dart:6217 name each other).

precedent(c: a forward-declared struct; ocaml: a signature before its implementation). Julia's
differs: it has no forward declaration, so an abstract type stands for the struct and its one
subtype is checked by reflection when the package loads.
"""
@quarantine "Julia has no forward struct declaration; a LambdaCallTarget's back-pointer to its Lambda names this abstract type" Core.DataType abstract type AbstractLambda end

# checked when every definition exists (src/WasmTarget.jl calls it after include_dart)
@quarantine "AbstractLambda's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractLambda})::Int = check_forward(AbstractLambda, Dart2Wasm.Lambda, @__MODULE__)

"""
    AbstractDispatchTable

The forward declaration of `Dart2Wasm.DispatchTable`, its one subtype: the type of a SelectorInfo's
`dispatch_table`, declared before SelectorInfo so that DispatchTable, which maps each id to its
SelectorInfo, can follow (dispatch_table.dart:30 and :396 name each other).

precedent(c: a forward-declared struct; ocaml: a signature before its implementation). Julia's
differs: it has no forward declaration, so an abstract type stands for the struct and its one
subtype is checked by reflection when the package loads.
"""
@quarantine "Julia has no forward struct declaration; a SelectorInfo's back-pointer to its DispatchTable names this abstract type" Core.DataType abstract type AbstractDispatchTable end

# checked when every definition exists (src/WasmTarget.jl calls it after include_dart)
@quarantine "AbstractDispatchTable's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractDispatchTable})::Int = check_forward(AbstractDispatchTable, Dart2Wasm.DispatchTable, @__MODULE__)
