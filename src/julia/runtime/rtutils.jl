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

# the module of the JS string builtins (`builtins: ['js-string']`, the JS String Builtins proposal's
# `wasm:js-string`), which the engine supplies or the JS runtime's polyfill stands in for
# (src/js/runtime_generator.jl's JS_POLYFILL_IMPORT): one name for both
@quarantine "dart's runtime names the JS string builtins' module in its polyfill import (pkg/dart2wasm/lib/js/runtime_generator.dart:150 jsStringPolyfill); WasmTarget's host imports read the same name" Core.String const JS_STRING_BUILTINS_MODULE::Core.String = "wasm:js-string"

"""
    host_modules() -> Vector{String}

The modules a WasmTarget host supplies to a module's imports: the keys of the JS runtime's
`baseImports` object (src/js/runtime_blob.jl, dart's runtime_blob.dart), read from its template, so
the host's import object is their one source, and the JS string builtins' module, which the engine
or the runtime's polyfill supplies (JS_STRING_BUILTINS_MODULE). A key the template fills in (`<<...>>`)
is the runtime's own, never a program's host library.
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
    push!(out, JS_STRING_BUILTINS_MODULE)
    return out
end

"""
    NirForeignImport

The callee of a foreign call to a library the host supplies, as Julia's ccall lowering reads it at
the call site (julia/src/ccall.cpp:1419 emit_ccall): its library and symbol (interpret_symbol_arg),
the Julia type each argument crosses as (`params`) and the declared return type (`rt`). A wasm
import: dart2wasm's ffi transformer makes a `@Native<sig>(symbol:, asset:)` declaration a synthesized
procedure `@pragma("wasm:import", "<asset>.<symbol>")` typed by its native signature
(pkg/dart2wasm/lib/ffi_native_transformer.dart:159 visitProcedure), which getFunction imports; this is
that procedure for one call site, typed, as dart types it, by the declared signature. An argument
declared `Any` is passed as the object reference it is (julia_to_native's boxed arm,
julia/src/ccall.cpp:528 julia_to_native): it crosses as its operand's inferred class, nullable as
`Any` admits `nothing`.

precedent(julia: julia/src/ccall.cpp:1980 function_sig_t::emit_a_ccall, which declares the callee in
the module by its symbol and the call site's signature, getOrInsertFunction). Julia's differs: a
foreign call is a statement, not a declaration, so each call site names its import.
"""
@quarantine "Julia's ccall lowering reads a foreign call's callee at its call site (julia/src/ccall.cpp:1419 emit_ccall); dart2wasm's ffi transformer makes the callee a wasm:import procedure (pkg/dart2wasm/lib/ffi_native_transformer.dart:159 visitProcedure)" Core.Type struct NirForeignImport
    lib::String
    name::String
    params::Vector{Type}
    rt::Type
end

"""
    nir_foreign_operands(node) -> Vector{NirValue}

The arguments a foreign call passes, one per declared argument type, Julia's `args[6:5+nccallargs]`
(julia/src/ccall.cpp:1419 emit_ccall); the GC roots after them are no argument.
"""
@quarantine "Julia's foreigncall lists its arguments after its five header operands (julia/src/ccall.cpp:1419 emit_ccall)" Core.SimpleVector function nir_foreign_operands(node::NirForeignCall)::Vector{NirValue}
    local at = node.args[3]
    at isa NirConst && at.c.val isa Core.SimpleVector ||
        reject!(Internal("src/julia/runtime/rtutils.jl nir_foreign_operands: a foreign call whose argument types are no constant svec"), "nir_foreign_operands")
    return node.args[6:5 + length(at.c.val)]
end

"""
    nir_foreign_import(body, node) -> Union{NirForeignImport,Nothing}

The host import a foreign call of `body` calls (NirForeignImport), read as Julia's ccall lowering
reads it (julia/src/ccall.cpp:1419 emit_ccall): its name a literal `(symbol, library)`
(interpret_symbol_arg) whose library is a host module (`host_modules`), its calling convention C
(convert_cconv), its argument count fixed. A call to any other library is no import, nothing, and the
code generator rejects it, located; a host call by another convention or with C varargs, which a
wasm import cannot take, rejects here, located.
"""
@quarantine "Julia's ccall lowering reads the callee's name, convention and signature from the foreigncall (julia/src/ccall.cpp:571 interpret_symbol_arg)" Core.SimpleVector function nir_foreign_import(body::NirBody, node::NirForeignCall)::Union{NirForeignImport,Nothing}
    local at = "src/julia/runtime/rtutils.jl nir_foreign_import"
    local sym = node.args[1]
    sym isa NirConst && sym.c.val isa Tuple{Union{Symbol,String},Union{Symbol,String}} || return nothing
    local item, lib = String(sym.c.val[1]), String(sym.c.val[2])
    lib in host_modules() || return nothing
    local rt, argtypes, nreq, cc = node.args[2], node.args[3], node.args[4], node.args[5]
    rt isa NirConst && rt.c.val isa Type && argtypes isa NirConst && argtypes.c.val isa Core.SimpleVector ||
        reject!(Internal("$at: the foreign call $lib.$item, whose return and argument types are no constants"), at)
    # convert_cconv: `ccall` is C's convention, the one a wasm import has
    local conv = cc isa NirConst ? (cc.c.val isa Tuple ? cc.c.val[1] : cc.c.val) : nothing
    conv === :ccall || conv === :cdecl ||
        reject!(Unquarantined("$at: the foreign call $lib.$item by the convention $(repr(conv)), where a wasm import takes C's"), at)
    # nreqargs > 0 is a C varargs function, which no wasm import's fixed arity takes
    nreq isa NirConst && nreq.c.val == 0 ||
        reject!(Unquarantined("$at: the foreign call $lib.$item of a C varargs function, which no wasm import's fixed arity takes"), at)
    all(t -> t isa Type, argtypes.c.val) ||
        reject!(Internal("$at: the foreign call $lib.$item, an argument type of which is no type: $(argtypes.c.val)"), at)
    local operands = nir_foreign_operands(node)
    local params = Type[t === Any ? Union{Nothing, nir_value_type(body, operands[i])} : t for (i, t) in enumerate(argtypes.c.val)]
    return NirForeignImport(lib, item, params, rt.c.val)
end
