# ============================================================================
# Main Compilation Entry Point
# ============================================================================

"""Declarative, typed substitutions for one closed-world compilation root."""
struct RootBindings
    captured_globals::Dict{Symbol,Tuple{Bool,UInt32}}
    captured_constants::Dict{Symbol,Any}
    dom_bindings::Dict{UInt32,Vector{Tuple{UInt32,Vector{Int32}}}}
    skip_stmts::Set{Int}
    invoke_imports::Dict{Int,UInt32}
    invoke_roots::Dict{Int,String}
    invoke_arguments::Dict{Int,Vector{Int}}
    bound_leaves::Vector{Tuple{Any,Tuple}}
    entry_calls::Vector{UInt32}
    elide_closure_context::Bool
    void_return::Bool
end

function RootBindings(; captured_globals=Dict{Symbol,Tuple{Bool,UInt32}}(),
                      captured_constants=Dict{Symbol,Any}(),
                      dom_bindings=Dict{UInt32,Vector{Tuple{UInt32,Vector{Int32}}}}(),
                      skip_stmts=Set{Int}(), invoke_imports=Dict{Int,UInt32}(),
                      invoke_roots=Dict{Int,String}(),
                      invoke_arguments=Dict{Int,Vector{Int}}(),
                      bound_leaves=Tuple{Any,Tuple}[],
                      entry_calls=UInt32[],
                      elide_closure_context::Bool=false, void_return::Bool=false)
    RootBindings(Dict{Symbol,Tuple{Bool,UInt32}}(captured_globals),
                 Dict{Symbol,Any}(captured_constants),
                 Dict{UInt32,Vector{Tuple{UInt32,Vector{Int32}}}}(dom_bindings),
                 Set{Int}(skip_stmts), Dict{Int,UInt32}(invoke_imports),
                 Dict{Int,String}(invoke_roots),
                 Dict{Int,Vector{Int}}(k => Int[v...] for (k, v) in invoke_arguments),
                 Tuple{Any,Tuple}[(f, Tuple(ts)) for (f, ts) in bound_leaves],
                 UInt32[entry_calls...],
                 elide_closure_context, void_return)
end

"""Add a nullable mutable reference global for initialization by a linked root."""
function add_uninitialized_ref_global!(mod::WasmModule, type_idx::Integer)::UInt32
    b = InstrBuilder(; func_name="uninitialized_framework_global", mod=mod)
    ref_null!(b, Int64(type_idx), ConcreteRef(UInt32(type_idx), true))
    return add_global_ref!(mod, type_idx, true, builder_code(b); nullable=true)
end

"""
    add_root_global_initializer!(mod, registry, global_idx, root_idx) -> UInt32

Create a module initializer that stores the result of a typed zero-argument
compilation root into a previously declared mutable reference global. Frameworks
use this for exact mutable initial values that cannot appear in a Wasm constant
expression. The initializer joins WT's canonical module-start composition.
"""
function add_root_global_initializer!(mod::WasmModule, registry::TypeRegistry,
                                      global_idx::Integer, root_idx::Integer)::UInt32
    0 <= global_idx < length(mod.globals) ||
        throw(ArgumentError("framework global index $global_idx is out of bounds"))
    global_def = mod.globals[Int(global_idx) + 1]
    global_def.mutable_ || throw(ArgumentError("framework global $global_idx is immutable"))
    root_type = _function_type(mod, root_idx)
    isempty(root_type.params) ||
        throw(ArgumentError("framework initializer root $root_idx must take no parameters"))
    length(root_type.results) == 1 ||
        throw(ArgumentError("framework initializer root $root_idx must return one value"))
    wasm_subtype(only(root_type.results), global_def.valtype, mod) ||
        throw(ArgumentError("framework initializer root result is incompatible with global $global_idx"))
    b = InstrBuilder(; func_name="framework_global_initializer", mod=mod)
    call!(b, root_idx, WasmValType[], root_type.results)
    global_set!(b, global_idx)
    end_block!(b)
    init_idx = add_function!(mod, WasmValType[], WasmValType[], WasmValType[],
                             builder_code(b))
    push!(registry.module_init_functions, init_idx)
    return init_idx
end

"""The one Julia-signature → physical Wasm-signature derivation."""
function function_wasm_signature(arg_types, return_type, global_args,
                                 mod::WasmModule, type_registry::TypeRegistry)
    pts = WasmValType[]
    for (j, T) in enumerate(arg_types)
        j in global_args && continue
        push!(pts, T isa Union && needs_anyref_boxing(T) ? AnyRef :
                   get_concrete_wasm_type(T, mod, type_registry))
    end
    rts = (return_type === Nothing || return_type === Union{}) ? WasmValType[] :
          WasmValType[get_concrete_wasm_type(return_type, mod, type_registry)]
    return pts, rts
end

"""
    compile_function(f, arg_types, func_name) -> WasmModule

Compile a Julia function to a WebAssembly module.
"""
function compile_function(f, arg_types::Tuple, func_name::String; optimize_ir::Bool=true)::WasmModule
    # Use compile_module for single functions too, enabling auto-discovery of dependencies
    # This ensures that cross-function calls work correctly
    return compile_module([(f, arg_types, func_name)]; optimize_ir=optimize_ir)
end

# ============================================================================
# STANDALONE_INTRINSIC_BODIES — Method-keyed, for entries function_data compiles
# as their OWN body (not a compile_invoke! call-site substitution).
#
# Every call site of `rethrow` is already replaced inline by compile_invoke!'s
# Method-keyed INVOKE_INTRINSICS (_invoke_rethrow_b, invoke.jl) — L115 covers
# that. But `rethrow`'s native body is itself just a bare `:foreigncall` to
# `jl_rethrow`/`jl_rethrow_other` with no lowering, and Julia's own closed-world
# discovery (collect_closed_world) adds `rethrow`'s MethodInstance to
# function_data as a real entry needing a compiled body whenever ANY reachable
# `:invoke` resolves to it — independently of whether compile_invoke! later
# replaces that call site. This is common: `try ... finally ... end` nested
# inside an enclosing `catch` lowers to an IMPLICIT `rethrow()` call on the
# exceptional path with no `rethrow` token anywhere in the Julia source
# (confirmed by deleting this arm: a differential test with two nested
# try/finally regions inside a catch failed to compile with no source-text
# `rethrow(` anywhere in the test file). The compiled body below is only ever
# reached as this closed-world placeholder; per L115 the actual call sites never
# call it. It ignores its argument, if any — `rethrow(e)`'s `e` is always the
# ALREADY-caught exception in `$current_exn`, so rethrowing the global slot is
# exact, not an approximation, for the only valid call shape (`rethrow()`/
# `rethrow(e)` from inside the handler that caught `e`).
# ============================================================================
const STANDALONE_INTRINSIC_BODIES = Dict{Method,Function}()

"""Populate STANDALONE_INTRINSIC_BODIES once, lazily, on first use."""
function _build_standalone_intrinsic_bodies!()
    isempty(STANDALONE_INTRINSIC_BODIES) || return nothing
    for m in methods(Base.rethrow)
        STANDALONE_INTRINSIC_BODIES[m] = _generate_rethrow_standalone_body
    end
    return nothing
end

"""The one standalone body every `Base.rethrow` MethodInstance compiles to when
function_data needs it as its own entry (see STANDALONE_INTRINSIC_BODIES above)."""
function _generate_rethrow_standalone_body(arg_types::Tuple, mod::WasmModule, type_registry::TypeRegistry;
                                           return_type::Union{Type,Nothing}=nothing)::Tuple{Vector{UInt8},Vector{WasmValType}}
    _ib_params = WasmValType[get_concrete_wasm_type(T, mod, type_registry) for T in arg_types]
    b = InstrBuilder(_ib_params, WasmValType[]; func_name="rethrow_standalone_body", mod=mod)
    ensure_exception_tag!(mod)
    global_get!(b, ensure_exception_global!(mod), AnyRef)
    ref_null!(b, ExternRef)
    throw_!(b, 0; inputs=WasmValType[AnyRef, ExternRef])
    end_block!(b)
    return (builder_code(b), WasmValType[])
end

"""Look up whether (f, arg_types) resolves to a Method registered in
STANDALONE_INTRINSIC_BODIES, and if so return its compiled body."""
function _standalone_intrinsic_body(f, arg_types::Tuple, mod::WasmModule, type_registry::TypeRegistry;
                                    return_type::Union{Type,Nothing}=nothing)::Union{Tuple{Vector{UInt8},Vector{WasmValType}},Nothing}
    f isa Function || return nothing
    _build_standalone_intrinsic_bodies!()
    isempty(STANDALONE_INTRINSIC_BODIES) && return nothing
    m = try
        which(f, arg_types)
    catch
        nothing
    end
    m === nothing && return nothing
    haskey(STANDALONE_INTRINSIC_BODIES, m) || return nothing
    return STANDALONE_INTRINSIC_BODIES[m](arg_types, mod, type_registry; return_type=return_type)
end

"""Return whether a typed `print`/`println`/`show` call has an explicit IO receiver.

`print(io, ...)` and `show(io, ...)` are ordinary Julia formatting calls.  They
must stay in the collected call graph; only receiver-free display calls use the
host IO bridge.  Confusing the two also used to append imports to a
framework-supplied module after it already contained local functions, shifting
every pre-existing function index.
"""
function _ir_call_has_explicit_io(stmt::Expr, code_info::Core.CodeInfo)::Bool
    first_type = Any
    if stmt.head === :invoke && !isempty(stmt.args) &&
       stmt.args[1] isa Core.MethodInstance
        spec = Base.unwrap_unionall(stmt.args[1].specTypes)
        if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 2
            first_type = spec.parameters[2]
        end
    else
        first_pos = stmt.head === :invoke ? 3 : 2
        if length(stmt.args) >= first_pos
            arg = stmt.args[first_pos]
            first_type = if arg isa Core.SSAValue &&
                            code_info.ssavaluetypes isa Vector &&
                            1 <= arg.id <= length(code_info.ssavaluetypes)
                code_info.ssavaluetypes[arg.id]
            elseif arg isa Core.Argument && code_info.slottypes !== nothing &&
                   1 <= arg.n <= length(code_info.slottypes)
                code_info.slottypes[arg.n]
            elseif arg isa QuoteNode
                typeof(arg.value)
            else
                typeof(arg)
            end
        end
    end
    first_type = try
        Core.Compiler.widenconst(first_type)
    catch
        Any
    end
    return first_type isa Type && first_type <: IO
end

"""
    _check_import_stub_external_types!(mod, registry, name, arg_types, wasm_idx, return_type)

Validate an `import_stubs` entry against dart2wasm's host-boundary restriction
(`translate_external_type`, `parity(translator.dart:1239 translateExternalType)`).
The host declares the import's REAL wasm signature directly via `add_import!`; the
Julia stub's `arg_types`/`return_type` are a SEPARATE declaration used only for
call-site resolution (`register_function!` below) — nothing previously checked
that the two agree. Because call-site coercion derives its target wasm type from
these SAME Julia types (never from the import's actual declared signature), any
divergence produces invalid wasm bytes at the call site with no diagnostic naming
the parameter — this closes that gap at registration time, loudly, before any
call is compiled. Every current caller (WasmMakie/Snapshot canvas providers:
`Float64`/`Int64` only) already agrees with `translate_external_type` byte-for-byte.
Skipped when `wasm_idx` is not an import index (defensive; `import_stubs` entries
are host imports by contract).
"""
function _check_import_stub_external_types!(mod::WasmModule, registry::TypeRegistry,
                                             name::AbstractString, arg_types::Tuple,
                                             wasm_idx::Integer, return_type::Type)
    Int(wasm_idx) < num_imported_funcs(mod) || return nothing
    ft = _function_type(mod, Int(wasm_idx))
    required_params = WasmValType[translate_external_type(T, mod, registry) for T in arg_types]
    if length(required_params) != length(ft.params)
        throw(WasmCompileError(WasmDiagnostic(:unsupported_type, String(name),
            "import \"$(name)\" declares $(length(ft.params)) wasm parameter(s) but the " *
            "Julia stub signature $(arg_types) has $(length(required_params)) — the host " *
            "boundary signature and the call-site Julia arg types must agree in arity",
            nothing, arg_types)))
    end
    for (i, (required, declared, T)) in enumerate(zip(required_params, ft.params, arg_types))
        required == declared || throw(WasmCompileError(WasmDiagnostic(:unsupported_type, String(name),
            "import \"$(name)\" parameter $(i) (::$(T)) crosses the host boundary as " *
            "$(declared) but dart2wasm's external-type restriction (translateExternalType, " *
            "translator.dart:1239) requires $(required) for this Julia type",
            nothing, T)))
    end
    required_results = (return_type === Nothing || return_type === Union{}) ? WasmValType[] :
                        WasmValType[translate_external_type(return_type, mod, registry)]
    required_results == ft.results || throw(WasmCompileError(WasmDiagnostic(:unsupported_type, String(name),
        "import \"$(name)\" returns $(ft.results) but dart2wasm's external-type " *
        "restriction (translateExternalType, translator.dart:1239) requires $(required_results) " *
        "for return type ::$(return_type)",
        nothing, return_type)))
    return nothing
end

"""
    compile_module(functions::Vector) -> WasmModule

Compile multiple Julia functions into a single WebAssembly module.

Each element of `functions` should be a tuple of (function, arg_types) or
(function, arg_types, name). If name is omitted, the function's name is used.

# Example
```julia
mod = compile_module([
    (add, (Int32, Int32)),
    (sub, (Int32, Int32)),
    (mul, (Int32, Int32), "multiply"),
])
```

Functions can call each other within the module.
"""
function _compile_closed_world_plan(functions::Vector;
                        existing_module::Union{WasmModule, Nothing}=nothing,
                        import_stubs::Vector=[],
                        root_bindings::Dict{String,RootBindings}=Dict{String,RootBindings}(),
                        link_roots::Union{Nothing,Function}=nothing,
                        return_registries::Bool=false,
                        optimize_ir::Bool=true,
                        register_ir_types::Bool=false
                        )
    # This private entry receives only a complete plan produced by
    # `trim_compile_plan`. It never discovers or silently adds functions.
    # Create WasmInterpreter with overlay method table (GPUCompiler pattern).
    # Must be created here (after user functions exist) so world age is current.
    interp = get_wasm_interpreter()

    # Filter out any discovered functions that are import stubs
    # (import stubs are registered in func_registry at their import indices, not compiled)
    if !isempty(import_stubs)
        import_stub_funcs = Set{Any}(entry[1] for entry in import_stubs)
        functions = filter(entry -> !(entry isa Tuple && entry[1] in import_stub_funcs), functions)
    end

    # SOUNDNESS: reset every per-module task-local cache for every compilation.
    # A framework-supplied `existing_module` is still a new component and must not
    # inherit type/function indices or callable identities from the previous one.
    clear_io_imports!()
    clear_rng_globals!()
    clear_perf_now!()
    clear_char_array_type!()
    clear_utf8_to_js_func!()

    # Create shared module and registries (or use the framework's predeclared module).
    if existing_module !== nothing
        mod = existing_module
    else
        mod = WasmModule()
    end
    type_registry = TypeRegistry()
    func_registry = FunctionRegistry()

    # Create base struct type FIRST — all other structs will be subtypes
    get_base_struct_type!(mod, type_registry)

    # Pre-register import stubs at their import indices in func_registry.
    # This enables compiled functions to call imports via cross-function call resolution.
    for entry in import_stubs
        func_ref, name, arg_types, wasm_idx, return_type = entry
        _check_import_stub_external_types!(mod, type_registry, name, arg_types, wasm_idx, return_type)
        register_function!(func_registry, name, func_ref, arg_types, UInt32(wasm_idx), return_type)
    end

    # Pre-register numeric box types for all common numeric Wasm types.
    # These are needed when functions with ExternRef return types (heterogeneous Unions)
    # need to return numeric values. Pre-registering avoids compilation order issues
    # where the caller's isa() check is compiled before the callee's box type exists.
    for nt in (I32, I64, F32, F64)
        get_numeric_box_type!(mod, type_registry, nt)
    end
    # Pre-register BoxedNothing type
    get_nothing_box_type!(mod, type_registry)

    # Normalize input: ensure each entry is (func, arg_types, name)
    normalized = []
    for entry in functions
        if length(entry) == 2
            f, arg_types = entry
            name = string(nameof(f))
            push!(normalized, (f, arg_types, name))
        else
            push!(normalized, entry)
        end
    end

    requested_names = Set(String(entry[3]) for entry in normalized)
    unknown_bindings = setdiff(Set(keys(root_bindings)), requested_names)
    isempty(unknown_bindings) || throw(ArgumentError(
        "root bindings do not match compilation roots: $(sort!(collect(unknown_bindings)))"))
    n_imported_functions = num_imported_funcs(mod)
    for (root_name, bindings) in root_bindings
        for (_, (_, global_idx)) in bindings.captured_globals
            Int(global_idx) < length(mod.globals) || throw(ArgumentError(
                "root $root_name references missing global index $global_idx"))
        end
        for (global_idx, updates) in bindings.dom_bindings
            Int(global_idx) < length(mod.globals) || throw(ArgumentError(
                "root $root_name DOM binding references missing global index $global_idx"))
            for (import_idx, _) in updates
                Int(import_idx) < n_imported_functions || throw(ArgumentError(
                    "root $root_name DOM binding references missing function import $import_idx"))
            end
        end
        for import_idx in values(bindings.invoke_imports)
            Int(import_idx) < n_imported_functions || throw(ArgumentError(
                "root $root_name invoke binding references missing function import $import_idx"))
        end
        unknown_targets = setdiff(Set(values(bindings.invoke_roots)), requested_names)
        isempty(unknown_targets) || throw(ArgumentError(
            "root $root_name invokes unknown compilation roots: $(sort!(collect(unknown_targets)))"))
        overlap_sites = intersect(Set(keys(bindings.invoke_imports)),
                                  Set(keys(bindings.invoke_roots)))
        isempty(overlap_sites) || throw(ArgumentError(
            "root $root_name binds invoke sites twice: $(sort!(collect(overlap_sites)))"))
        unknown_argument_sites = setdiff(Set(keys(bindings.invoke_arguments)),
            union(Set(keys(bindings.invoke_imports)), Set(keys(bindings.invoke_roots))))
        isempty(unknown_argument_sites) || throw(ArgumentError(
            "root $root_name selects arguments for unbound invoke sites: " *
            "$(sort!(collect(unknown_argument_sites)))"))
        for target_idx in bindings.entry_calls
            Int(target_idx) < n_imported_functions + length(mod.functions) ||
                throw(ArgumentError(
                    "root $root_name entry call references missing function $target_idx"))
        end
    end

    # Scan all functions for println/print/show usage and add IO imports if needed
    needs_io = false
    for (f, arg_types, fname) in normalized
        try
            ci, _ = get_typed_ir(f, arg_types; optimize=optimize_ir, interp=interp)
            for stmt in ci.code
                if stmt isa Expr && (stmt.head === :invoke || stmt.head === :call)
                    func_arg = stmt.head === :invoke ? stmt.args[2] : stmt.args[1]
                    if func_arg isa GlobalRef &&
                       (func_arg.name === :println || func_arg.name === :print ||
                        func_arg.name === :show) &&
                       !_ir_call_has_explicit_io(stmt, code_info)
                        needs_io = true
                        break
                    end
                end
            end
        catch
            # If IR fails, skip — the main compilation loop will handle errors
        end
        needs_io && break
    end
    if needs_io
        io_imports = add_io_imports!(mod, type_registry)
        set_io_imports!(io_imports)
    else
        clear_io_imports!()
    end

    # Scan for jl_get_current_task (rand() usage) and add RNG globals if needed
    needs_rng = false
    for (f, arg_types, fname) in normalized
        try
            ci, _ = get_typed_ir(f, arg_types; optimize=optimize_ir, interp=interp)
            for rec in build_nir(ci)
                if rec.slot == 0 && rec.node isa NirForeignCall &&
                   rec.node.c_symbol === :jl_get_current_task
                    needs_rng = true
                    break
                end
            end
        catch
        end
        needs_rng && break
    end
    if needs_rng
        ensure_rng_globals!(mod)
    else
        clear_rng_globals!()
    end

    # Track all required globals across all functions
    required_globals = Dict{Int, Tuple{WasmValType, Type}}()  # global_idx -> (wasm_type, julia_elem_type)

    # First pass: register types, detect WasmGlobals, and reserve function slots
    # We need to know all function indices before compiling bodies
    # (f, arg_types, name, typed IR, return_type, global_args, is_closure, NIR body) per
    # function — the typed IR only for ir.jl's closed-world type collector; codegen reads
    # the NIR body, built once here
    function_data = []

    for (f, arg_types, name) in normalized
        # Check if this is a closure (function with captured variables)
        # A TYPE-KEYED entry (f IS the closure DataType — capturing
        # closures have no instance) resolves IR by ftype, and the closure type
        # is f itself, not typeof(f).
        local _type_keyed_closure = f isa DataType && is_closure_type(f)
        closure_type = _type_keyed_closure ? f : typeof(f)
        is_closure = is_closure_type(closure_type)

        # Get typed IR using the ORIGINAL arg_types (without closure type prepend).
        # Base.code_typed already knows the first slot is typeof(f) for closures.
        # (type-keyed closures resolve via the TRIM_IR_CACHE hit — trimcollect
        # cached their pair under (T, arg_types); a miss errors loudly.)
        typed, return_type = get_typed_ir(f, arg_types; optimize=optimize_ir, interp=interp)

        bindings = get(root_bindings, name, nothing)
        elide_closure_context = bindings !== nothing && bindings.elide_closure_context
        if elide_closure_context
            overlap = intersect(Set(keys(bindings.captured_globals)),
                                Set(keys(bindings.captured_constants)))
            isempty(overlap) || throw(ArgumentError(
                "root $name binds closure fields twice: $(sort!(collect(overlap)))"))
            missing_fields = Symbol[field for field in fieldnames(closure_type)
                                    if !haskey(bindings.captured_globals, field) &&
                                       !haskey(bindings.captured_constants, field)]
            isempty(missing_fields) || throw(ArgumentError(
                "root $name cannot elide closure context; unsubstituted fields: $(missing_fields)"))
        end
        bindings !== nothing && bindings.void_return && (return_type = Nothing)

        if is_closure && !elide_closure_context
            # Prepend the closure type to arg_types for type registration and WASM codegen
            arg_types = (closure_type, arg_types...)
        end

        # Detect WasmGlobal arguments
        global_args = Set{Int}()
        for (i, T) in enumerate(arg_types)
            if T <: WasmGlobal
                push!(global_args, i)
                elem_type = global_eltype(T)
                wasm_type = julia_to_wasm_type(elem_type)
                global_idx = global_index(T)
                required_globals[global_idx] = (wasm_type, elem_type)
            end
        end

        # Register the signature's types (skip WasmGlobal)
        for (i, T) in enumerate(arg_types)
            i in global_args && continue
            register_reachable_type!(mod, type_registry, T)
        end
        register_reachable_type!(mod, type_registry, return_type)

        push!(function_data, (f, arg_types, name, typed, return_type, global_args, is_closure,
                              typed === nothing ? nothing : nir_body(typed)))
    end

    # Add all required globals to the module
    for global_idx in sort(collect(keys(required_globals)))
        wasm_type, elem_type = required_globals[global_idx]
        while length(mod.globals) <= global_idx
            add_global!(mod, wasm_type, true, zero(elem_type))
        end
    end

    # Exception objects synthesized by lowering must join the closed component
    # before DFS class IDs freeze; late registration makes catch-side `isa`
    # structurally unable to classify an otherwise real payload.
    for _exn_T in (ErrorException, ArgumentError, OverflowError, DivideError,
                   StackOverflowError, OutOfMemoryError, BoundsError, TypeError,
                   DomainError, InexactError, KeyError, MethodError,
                   AssertionError, UndefVarError, FieldError)
        register_struct_type!(mod, type_registry, _exn_T)
    end

    # JIB-IR001: Pre-register Core IR types for self-hosting dispatch
    if register_ir_types
        register_core_ir_types!(mod, type_registry)
    end

    # Create $JlType hierarchy types FIRST (the closed-world
    # collector below registers structs whose DataType-typed fields must resolve to
    # $JlDataType — pre-hierarchy registration resolved them to a stale struct type,
    # which the Any-only patch pass below can't fix)
    create_jl_type_hierarchy!(mod, type_registry)

    # Census F2 CLOSE THE TYPE UNIVERSE BEFORE NUMBERING — dart numbers the
    # whole component ONCE, before codegen (class_info.dart:583-690). Walk every
    # function's typed IR and COLLECT every reachable concrete struct / union member
    # so the DFS below numbers the closed world (real [low, high] ranges for isa/
    # typeassert). Collection ONLY — no struct registration: eagerly registering
    # changed field-resolution ORDER and produced duplicate layouts (caught by
    # WasmMakie's E-001); numbering needs no wasm struct to exist, and a type
    # registered lazily later receives its pre-assigned id via ensure_type_id!.
    _reachable = _collect_reachable_ir_types(function_data)

    # Assign DFS type IDs (the closed world = registered + reachable)
    assign_type_ids!(type_registry; extra_concrete_types=_reachable)

    # Create BoxedNothing singleton global (after type IDs assigned)
    get_nothing_global!(mod, type_registry)

    # Patch struct types registered before JlType hierarchy existed.
    # Any-typed fields were mapped to ExternRef (since jl_type_idx was nothing).
    # Now that the hierarchy exists, patch them to AnyRef.
    patch_any_fields_for_jltype_hierarchy!(mod, type_registry)

    # Create DataType globals for ALL types with DFS IDs + type lookup table
    ensure_all_type_globals!(mod, type_registry)
    create_type_lookup_table!(mod, type_registry)

    # String hashing needs no pre-created helper function: hash(::String,::UInt)/
    # hash(::SubString{String},::UInt) are overlaid with a pure-Julia,
    # bit-exact-with-native port of the native algorithm (interpreter.jl,
    # "String hash Overlay") that compiles through the ordinary :invoke path
    # like any other Julia function — no special-cased wasm helper needed.

    # Pre-create the shared utf8proc property table/helper before function-index
    # assignment. Both category and character width read the same packed byte.
    needs_unicode_properties = false
    for fd in function_data
        fn_nir = fd[8]
        fn_nir === nothing && continue
        for rec in fn_nir.stmts
            if rec.slot == 0 && rec.node isa NirForeignCall &&
               rec.node.c_symbol in (:utf8proc_category, :utf8proc_charwidth,
                                     :jl_id_start_char, :jl_id_char)
                needs_unicode_properties = true
                break
            end
        end
        needs_unicode_properties && break
    end
    needs_unicode_properties && get_or_create_unicode_property_func!(mod, type_registry)

    # LAZY constants: collect long (>64B) String/Symbol literals and pre-create
    # their init functions NOW — the same index-freeze constraint (functions cannot be
    # added during body compilation without shifting indices). dart constants.dart:454.
    for fd in function_data
        fn_nir = fd[8]
        fn_nir === nothing && continue
        for rec in fn_nir.stmts
            for v in nir_literal_values(rec)
                if v isa String && ncodeunits(v) > 64
                    get_or_create_lazy_string!(mod, type_registry, v)
                elseif v isa Symbol && ncodeunits(String(v)) > 64
                    get_or_create_lazy_string!(mod, type_registry, String(v))
                end
            end
        end
    end

    # Calculate function indices (accounting for imports + pre-created helper functions)
    # Functions are added in order, so index = n_imports + n_existing + position - 1
    n_imports = length(mod.imports)
    # fullstrict PRE-DECLARED SIGNATURES: the one derivation both the placeholder
    # (registration) and the body fill use — the builder's call! deriver then reads
    # TRUTH for every function from the moment indices exist (the 19 empty-sig call
    # sites + all cross-calls stop guessing; declare-then-define, like an assembler).
    n_existing = length(mod.functions)  # includes pre-created helper functions
    # T1.1 step 2: discovery-added dynamic-dispatch candidates (beyond the base
    # collection) register as is_candidate=true → visible to the call-site typeId
    # switch (by_ref) but invisible to get_function cross-call resolution.
    _disp_cands = _TRIM_DISPATCH_CANDIDATES[]
    for (i, (f, arg_types, name, _, return_type, global_args, _)) in enumerate(function_data)
        func_idx = UInt32(n_imports + n_existing + i - 1)
        register_function!(func_registry, name, f, arg_types, func_idx, return_type;
                           is_candidate = (!isempty(_disp_cands) && (f, arg_types) in _disp_cands))
        # fullstrict: the PLACEHOLDER carries the true signature from birth
        local _pp, _rr = function_wasm_signature(arg_types, return_type, global_args,
                                                  mod, type_registry)
        local _ft_idx = add_type!(mod, FuncType(WasmValType[p for p in _pp], WasmValType[r for r in _rr]))
        push!(mod.functions, WasmFunction(UInt32(_ft_idx), WasmValType[], UInt8[Opcode.UNREACHABLE, Opcode.END]))
    end

    # THE CLOSURE VTABLE PRE-PASS (the index-freeze rule: nothing
    # may add functions during body compilation). Trampolines + vtable globals for
    # every type-keyed userland closure are created NOW; their bodies' FINAL indices
    # are computable deterministically (bodies start after the K trampolines).
    local _cvp = Tuple{Int, DataType, Bool}[] # (function_data position, callable type, takes context)
    for (i, (f, _, _, _, _, _, _)) in enumerate(function_data)
        if f isa DataType && is_closure_type(f)
            push!(_cvp, (i, f, true))
        elseif f isa Function && typeof(f) in _ENROLLED_CALLABLE_TYPES[]
            push!(_cvp, (i, typeof(f), false))
        end
    end
    if !isempty(_cvp)
        # ONE vtable per callable TYPE, holding every specialization the closed world
        # contains (one trampoline per arity — dart's per-shape entries); grouped in
        # program order so the trampolines' indices are deterministic.
        local _cv_types = DataType[]
        local _cv_bodies = Dict{DataType, Vector{ClosureBody}}()
        local _cv_ctx = Dict{DataType, Bool}()
        for (_i, _T, _takes_context) in _cvp
            local _entry = function_data[_i]
            local _ats, _rt = _entry[2], _entry[5]
            # fullstrict reorder: the placeholders occupy the body indices ALREADY —
            # the standard formula reads them; trampolines append after.
            local _body_idx = UInt32(n_imports + n_existing + _i - 1)
            local _bps = WasmValType[get_concrete_wasm_type(T2, mod, type_registry) for T2 in _ats]
            local _brs = (_rt === Nothing || _rt === Union{}) ? WasmValType[] :
                         WasmValType[get_concrete_wasm_type(_rt, mod, type_registry)]
            haskey(_cv_bodies, _T) || (push!(_cv_types, _T); _cv_bodies[_T] = ClosureBody[]; _cv_ctx[_T] = _takes_context)
            push!(_cv_bodies[_T], ClosureBody(_body_idx, _bps, _brs, _rt, Type[T2 for T2 in _ats]))
        end
        for _T in _cv_types
            build_closure_vtable!(mod, type_registry, _T, _cv_bodies[_T]; takes_context=_cv_ctx[_T])
        end
    end

    if link_roots !== nothing
        imports_before_link = length(mod.imports)
        root_indices = Dict{String,UInt32}(
            name => UInt32(n_imports + n_existing + i - 1)
            for (i, (_, _, name, _, _, _, _)) in enumerate(function_data))
        link_roots(mod, root_indices, type_registry)
        length(mod.imports) == imports_before_link || throw(ArgumentError(
            "the root linker cannot add imports after function indices are frozen"))
    end



    # Build dispatch tables for megamorphic functions (>8 specializations)
    # Phase 1: metadata (signatures, globals, tables) — needed by emit_dispatch_call! during body compilation
    dispatch_registry = build_dispatch_tables(func_registry, type_registry)

    if !isempty(dispatch_registry.tables)
        emit_dispatch_metadata!(mod, type_registry, dispatch_registry)
        # parity(dispatch_table.dart:501 DispatchTable.build): pack single-axis selectors into the ONE dart table
        pack_dispatch_selectors!(mod, dispatch_registry, type_registry)
    end

    # Track export names to avoid duplicates (WASM requires unique export names)
    export_name_counts = Dict{String, Int}()

    # Second pass: compile function bodies
    for (i, (f, arg_types, name, _, return_type, global_args, is_closure, fn_nir)) in enumerate(function_data)
        func_idx = UInt32(n_imports + n_existing + i - 1)

        local body::Vector{UInt8}
        local locals::Vector{WasmValType}

        standalone_body = _standalone_intrinsic_body(f, arg_types, mod, type_registry; return_type=return_type)

        # Check if this function is a dispatch caller (calls a megamorphic function
        # with abstract args). If so, generate a direct dispatch body instead of the normal body.
        dispatch_dt = nothing
        if fn_nir !== nothing && type_registry.base_struct_idx !== nothing &&
           !isempty(dispatch_registry.tables)
            dispatch_dt = find_dispatch_call(fn_nir.stmts, dispatch_registry)
        end

        if standalone_body !== nothing
            body, locals = standalone_body
        elseif dispatch_dt !== nothing
            # Generate dispatch-only body (probe + call_indirect + return)
            n_params = sum(j -> !(j in global_args) ? 1 : 0, 1:length(arg_types); init=0)
            if haskey(dispatch_registry.selector_offset, dispatch_dt.func_ref)
                # parity(code_generator.dart:2028 CodeGenerator._virtualCall): the dart virtual call — classId + offset + call_indirect
                body, locals = generate_selector_caller_body(
                    dispatch_dt, dispatch_registry, n_params, type_registry.base_struct_idx;
                    caller_return_type=return_type, mod=mod, type_registry=type_registry)
            else
                body, locals = generate_dispatch_caller_body(
                    dispatch_dt, n_params, type_registry.base_struct_idx, type_registry)
            end
        else
            # Generate function body from Julia IR
            bindings = get(root_bindings, name, nothing)
            local _root_invokes = bindings === nothing ? Dict{Int,UInt32}() :
                Dict{Int,UInt32}(site => UInt32(n_imports + n_existing +
                    findfirst(d -> d[3] == target, function_data) - 1)
                    for (site, target) in bindings.invoke_roots)
            local _bound_invokes = bindings === nothing ? Dict{Int,UInt32}() :
                merge(bindings.invoke_imports, _root_invokes)
            ctx = CompilationContext(fn_nir, arg_types, return_type, mod, type_registry;
                                    func_registry=func_registry, func_idx=func_idx, func_ref=f,
                                    global_args=global_args,
                                    is_compiled_closure=is_closure &&
                                        !(bindings !== nothing && bindings.elide_closure_context),
                                    captured_signal_fields=bindings === nothing ?
                                        Dict{Symbol,Tuple{Bool,UInt32}}() : bindings.captured_globals,
                                    captured_constant_fields=bindings === nothing ?
                                        Dict{Symbol,Any}() : bindings.captured_constants,
                                    dom_bindings=bindings === nothing ?
                                        Dict{UInt32,Vector{Tuple{UInt32,Vector{Int32}}}}() : bindings.dom_bindings,
                                    skip_stmts=bindings === nothing ? Set{Int}() : bindings.skip_stmts,
                                    invoke_imports=_bound_invokes)
            ctx.entry_calls = bindings === nothing ? UInt32[] : copy(bindings.entry_calls)
            ctx.invoke_arguments = bindings === nothing ? Dict{Int,Vector{Int}}() :
                deepcopy(bindings.invoke_arguments)
            # Preserve structured compiler/validation errors and their complete
            # diagnostic ledgers. The context already carries the root function
            # and source location; converting failures to ErrorException here
            # erased the machine-readable contract used by framework callers.
            body = generate_body(ctx)
            locals = ctx.locals
        end

        # fullstrict: FILL the pre-declared placeholder (same signature derivation)
        param_types, result_types = function_wasm_signature(arg_types, return_type, global_args,
                                                             mod, type_registry)
        local _slot = Int(func_idx) - n_imports + 1
        local _ft_idx2 = add_type!(mod, FuncType(WasmValType[p for p in param_types], WasmValType[r for r in result_types]))
        mod.functions[_slot] = WasmFunction(UInt32(_ft_idx2), WasmValType[l for l in locals], body)
        actual_idx = func_idx

        # Export the function with a unique name
        export_name = name
        count = get(export_name_counts, name, 0)
        if count > 0
            export_name = "$(name)_$(count)"
        end
        export_name_counts[name] = count + 1
        add_codegen_export!(mod, export_name, 0, actual_idx)
    end

    # Phase 2: Add wrapper functions AFTER all actual functions are compiled.
    # This ensures entry.target_idx values (from func_registry) point to correct indices.
    if !isempty(dispatch_registry.tables)
        emit_dispatch_wrappers!(mod, type_registry, dispatch_registry)
    end

    # Phase 2: Add overlay wrapper functions

    # Populate DataType/TypeName fields for type constant globals.
    # This creates a start function that patches .name, .super, .parameters, .wrapper.
    populate_type_constant_globals!(mod, type_registry)
    finalize_module_initializers!(mod, type_registry)

    # Clear module-level state after compilation
    clear_io_imports!()
    clear_rng_globals!()
    clear_perf_now!()
    clear_char_array_type!()
    clear_utf8_to_js_func!()

    if return_registries
        return (mod, type_registry, func_registry, dispatch_registry)
    end
    return mod
end

"""
    compile_module_from_ir(ir_entries::Vector)::WasmModule

Compile pre-computed typed CodeInfo entries to a WasmModule, bypassing Base.code_typed().
Each entry is (typed::Core.CodeInfo, return_type::Type, arg_types::Tuple, name::String).
Optionally a 5th element func_ref can be provided for cross-function call resolution.

This is the entry point for the eval_julia pipeline where type inference has already been run.
Unlike `compile_module`, this adapter starts from caller-supplied typed IR rather than
running inference, then enters the same closed-world module compiler.
"""
struct _PrecomputedIRKey
    id::Int
end

function compile_module_from_ir(ir_entries::Vector)::WasmModule
    functions = Any[]
    cache = IdDict{Any, Tuple{Core.CodeInfo, Any}}()
    for (i, entry) in enumerate(ir_entries)
        length(entry) >= 4 || throw(ArgumentError(
            "IR entry $i must be (CodeInfo, return_type, arg_types, name[, func_ref])"))
        typed, return_type, arg_types, name = entry[1], entry[2], entry[3], entry[4]
        typed isa Core.CodeInfo || throw(ArgumentError("IR entry $i does not contain Core.CodeInfo"))
        arg_types isa Tuple || throw(ArgumentError("IR entry $i arg_types must be a Tuple"))
        key = length(entry) >= 5 && entry[5] !== nothing ? entry[5] : _PrecomputedIRKey(i)
        push!(functions, (key, arg_types, String(name)))
        cache[(key, arg_types)] = (typed, return_type)
    end

    previous = TRIM_IR_CACHE[]
    TRIM_IR_CACHE[] = cache
    try
        return _compile_closed_world_plan(functions)
    finally
        TRIM_IR_CACHE[] = previous
    end
end

# ============================================================================
# Browser byte-vector accessors. These are ordinary Julia functions compiled through
# the canonical closed-world pipeline when an embedder requests them; they are not
# a compiler or serializer path.
wasm_bytes_length(v::Vector{UInt8})::Int32 = Int32(length(v))
wasm_bytes_get(v::Vector{UInt8}, i::Int32)::Int32 = Int32(v[i])

# The sole module pipeline: collect one closed world, install its paired typed-IR
# cache for the duration of codegen, then compile that immutable plan. Public
# entry points may normalize inputs, but none may bypass this collector.
function _compile_module_trim(functions::Vector; kwargs...)
    normalized = Any[]
    for entry in functions
        if length(entry) == 2
            f, arg_types = entry
            push!(normalized, (f, arg_types, string(nameof(f))))
        else
            push!(normalized, entry)
        end
    end
    import_stubs = get(kwargs, :import_stubs, Any[])
    external_entries = Any[(entry[1], Tuple(entry[3])) for entry in import_stubs]
    root_bindings = get(kwargs, :root_bindings, Dict{String,RootBindings}())
    for bindings in values(root_bindings), (f, arg_types) in bindings.bound_leaves
        push!(external_entries, (f, arg_types))
    end
    plan, ir_cache = trim_compile_plan(normalized; external_entries)
    TRIM_IR_CACHE[] = ir_cache
    try
        return _compile_closed_world_plan(plan; kwargs...)
    finally
        TRIM_IR_CACHE[] = nothing
    end
end

function compile_module(functions::Vector;
                        existing_module::Union{WasmModule, Nothing}=nothing,
                        import_stubs::Vector=[],
                        root_bindings::Dict{String,RootBindings}=Dict{String,RootBindings}(),
                        link_roots::Union{Nothing,Function}=nothing,
                        return_registries::Bool=false,
                        optimize_ir::Bool=true,
                        register_ir_types::Bool=false,
                        discovery::Symbol=:trim)
    discovery === :trim || throw(ArgumentError(
        "only the closed-world compilation path is supported (discovery=:trim)"))
    return _compile_module_trim(functions;
        existing_module, import_stubs, return_registries,
        root_bindings, link_roots, optimize_ir, register_ir_types)
end

# _collect_reachable_ir_types (Phase 12B, the closed-world type collector) lives in
# ir.jl — it is the boundary's OWN input side, consuming raw CodeInfo exactly like
# get_typed_ir (R29a/R29b exempt ir.jl for the same reason).

# Julia may discover several specialized functions with the same source-level name.
# Name disambiguation is a CODEGEN policy; the low-level module builder, like dart's
# ExportsBuilder, rejects duplicate names instead of silently repairing the request.
function add_codegen_export!(mod::WasmModule, name::String, kind::Integer, idx::Integer)
    final = name
    if any(e -> e.name == final, mod.exports)
        local k = 2
        while any(e -> e.name == string(name, "_d", k), mod.exports)
            k += 1
        end
        final = string(name, "_d", k)
    end
    return add_export!(mod, final, kind, idx)
end
