# The raises of Julia's own C runtime (src/rtutils.c, src/runtime_intrinsics.c), which Julia's codegen
# calls where a builtin or an intrinsic fails: each builds Julia's exception and throws it through the
# runtime's thrower (src/runtime/common/errors_patch.jl Error._throwWithCurrentStackTrace). They have
# no dart counterpart: dart raises its own errors in dart code (boxed_int.dart's
# `throw IntegerDivisionByZeroException()`), where Julia's are raised by its runtime, so they are
# quarantined, each naming Julia's exception, and kept in every closed world (RUNTIME_ENTRY_POINTS).

# jl_diverror_exception, raised by checked_sdiv_int and its kin at a zero divisor (runtime_intrinsics.c)
@quarantine "Julia's runtime raises DivideError where a checked integer division fails" Core.DivideError @noinline throw_divide_error()::Union{} =
    Runtime.Error__throw_with_current_stack_trace(DivideError())

# jl_undefref_exception, raised where an undefined field or array element is read (rtutils.c)
@quarantine "Julia's runtime raises UndefRefError where an undefined reference is read" Core.UndefRefError @noinline throw_undef_ref_error()::Union{} =
    Runtime.Error__throw_with_current_stack_trace(UndefRefError())

# jl_bounds_error_int, raised with the indexed value and the integer index where a bounds check fails
# (rtutils.c); BoundsError's constructor specializes on its index, so the index is an Int, as the C
# runtime's size_t
@quarantine "Julia's runtime raises BoundsError with the value and the index where a bounds check fails" Core.BoundsError @noinline throw_bounds_error(@nospecialize(a::Any), i::Int)::Union{} =
    Runtime.Error__throw_with_current_stack_trace(BoundsError(a, i))

"""
    nir_runtime_member(world, f) -> Core.MethodInstance

The MethodInstance of the runtime's function `f` in the closed world `world`: an entry point's
(RUNTIME_ENTRY_POINTS keeps each) or a callee one reaches, its one specialization there, the method
dart2wasm's KernelNodes names by `index.getProcedure`. None, or more than one, is WasmTarget's own
defect.
"""
@quarantine "the runtime's method is found among the closed world's CodeInstances, by its Method" Core.MethodInstance function nir_runtime_member(world::NirWorld, f::Function, at::String)::Core.MethodInstance
    local ms = methods(f)
    local hits = Core.MethodInstance[b.ci.def for b in world if b.ci.def.def in ms]
    length(hits) == 1 || reject!(Internal("src/julia/runtime/rtutils.jl nir_runtime_member: $f has $(length(hits)) specializations in the closed world, not one"), at)
    return only(hits)
end

# the exception tag's export name (src/tags.jl _define_dart_exception_tag): a host matches a Julia
# exception by the tag the main module exports under it. `$` keeps it apart from every export a
# program names, a Julia identifier holding none
@quarantine "dart exports no tag for its host; a Julia program's host matches its exceptions by the exported tag" Core.String const EXCEPTION_TAG_EXPORT::Core.String = "\$exceptionTag"

"""
    host_modules() -> Vector{String}

The modules a WasmTarget host supplies to a module's imports: the keys of the JS runtime's
`baseImports` object (src/js/runtime_blob.jl, dart's runtime_blob.dart), read from its template, so
the host's import object is their one source. A key the template fills in (`<<...>>`) is the
runtime's own, never a program's host library.
"""
@quarantine "Julia's foreign call names a library; the host's libraries are the keys of the JS runtime's import object" Base.match function host_modules()::Vector{String}
    local parts = Dart2Wasm.js_runtime_blob_template[]._parts
    local text = join(p isa Dart2Wasm._TemplateStringPart ? p.string : "<<>>" for p in parts)
    local block = match(r"const baseImports = \{\n(.*?)\n\s*\};"s, text)
    block === nothing && reject!(Internal("src/julia/runtime/rtutils.jl host_modules: the JS runtime's template holds no baseImports object"), "host_modules")
    local out = String[]
    local depth = 0
    for line in split(block[1], '\n')
        local key = match(r"^\s*([A-Za-z_$][\w$]*)\s*:", line)
        depth == 0 && key !== nothing && push!(out, String(key[1]))
        depth += count(==('{'), line) - count(==('}'), line)
    end
    return out
end

"""
    nir_host_import(world, mi) -> Union{Tuple{String,String},Nothing}

The host import a method is, `(module, name)`, the quarantined host import of a Julia foreign call
(dev/MARCH.md 1.F), dart's `@pragma("wasm:import", "<module>.<name>")`, read from the method's
inferred body in the closed world, its one source: a body that is one foreign call of a literal
`(name, library)` whose library is a host module (`host_modules`), its declared argument types the
method's own and its arguments the method's, in order, its result returned. Any other method, a
foreign call to another library among them (libjulia's `jl_uv_puts`, a C library), is no import:
its body is compiled, and the code generator rejects its foreign call, located.

precedent(clang: `__attribute__((import_module("m"), import_name("n")))` on a wasm function
declaration; dart: the ffi transformer's `wasm:import` for an `@Native`). Julia's differs: a foreign
call is a statement of a method's body, not a declaration, so the method whose whole body it is
stands for the declaration.
"""
@quarantine "Julia's foreign call is a statement; the method whose whole body it is stands for dart's wasm:import declaration" Core.SimpleVector function nir_host_import(world::NirWorld, mi::Core.MethodInstance)::Union{Tuple{String,String},Nothing}
    local body = nir_body_of(world, mi)
    length(body.stmts) == 2 || return nothing
    local call, ret = body.stmts[1], body.stmts[2]
    call isa NirForeignCall && ret isa NirReturn || return nothing
    local name = call.args[1]
    name isa NirConst && name.c.val isa Tuple{Symbol,String} || return nothing
    local item, lib = name.c.val
    lib in host_modules() || return nothing
    local rt, ats = call.args[2], call.args[3]
    local params = Any[Base.unwrap_unionall(mi.specTypes).parameters[2:end]...]
    rt isa NirConst && ats isa NirConst && ats.c.val isa Core.SimpleVector || return nothing
    Any[ats.c.val...] == params || return nothing
    all(i -> call.args[5 + i] == NirArgument(i + 1), eachindex(params)) || return nothing
    ret.val == NirSSA(1) || rt.c.val === Nothing && ret.val == NirConst(Core.Const(nothing)) || return nothing
    return (lib, String(item))
end
