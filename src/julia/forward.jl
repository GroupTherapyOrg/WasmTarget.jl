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

A forward declaration's check: `sole` subtypes `forward`, and no other type that `mod` or a
submodule of it defines does. Throws a `ConstructionViolation` naming the first other subtype.
"""
@quarantine "the forward declaration's one subtype, found by reflection over the package's bindings" Base.names function check_forward(forward::DataType, sole::DataType, mod::Module)::Int
    sole <: forward || throw(ConstructionViolation(string(nameof(forward)), "$sole does not subtype it"))
    for n in names(mod; all = true)
        isdefined(mod, n) || continue
        local b = getglobal(mod, n)
        if b isa Module
            b !== mod && parentmodule(b) === mod && check_forward(forward, sole, b)
        elseif b isa DataType && b <: forward && b !== forward && b !== sole
            throw(ConstructionViolation(string(nameof(forward)), "$mod.$n subtypes it, where $sole is its one subtype"))
        end
    end
    return 0
end

# checked when every definition exists (src/WasmTarget.jl calls it after include_dart)
@quarantine "AbstractModule's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractModule})::Int = check_forward(AbstractModule, WasmBuilder.IR.Module, @__MODULE__)
@quarantine "AbstractModuleBuilder's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractModuleBuilder})::Int = check_forward(AbstractModuleBuilder, WasmBuilder.ModuleBuilder, @__MODULE__)
@quarantine "AbstractInstructionsBuilder's assertion, run when the package loads" Base.Val construction_check(::Val{:AbstractInstructionsBuilder})::Int = check_forward(AbstractInstructionsBuilder, WasmBuilder.InstructionsBuilder, @__MODULE__)
