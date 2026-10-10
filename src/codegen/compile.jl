# ============================================================================
# Main Compilation Entry Point
# ============================================================================

"""Declarative, typed substitutions for one closed-world compilation root.
parity(quarantine: the substitutions one compilation root carries for a host framework (captured signal globals and constants, a linked root's initializer); dart2wasm compiles one program with one main.)"""
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

# parity(quarantine: the substitutions one compilation root carries for a host framework (captured signal globals and constants, a linked root's initializer); dart2wasm compiles one program with one main.)
function RootBindings(; captured_globals=Dict{Symbol,Tuple{Bool,UInt32}}(),
                      captured_constants=Dict{Symbol,Any}(),
                      dom_bindings=Dict{UInt32,Vector{Tuple{UInt32,Vector{Int32}}}}(),
                      skip_stmts=Set{Int}(), invoke_imports=Dict{Int,UInt32}(),
                      invoke_roots=Dict{Int,String}(),
                      invoke_arguments=Dict{Int,Vector{Int}}(),
                      bound_leaves=Tuple{Any,Tuple}[],
                      entry_calls=UInt32[],
                      elide_closure_context::Bool=false, void_return::Bool=false)::RootBindings
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

# A global index a framework or a WasmGlobal argument names is never the count of open calls of
# host-declared imports, `\$host_imports_open`, which only the host's glue writes (host_glue_js);
# a global the host imports for itself is the host's to name. A framework names the index before
# or without a compile, so the count is found as the setup imported it (_imported_global).
# parity(quarantine: Julia's host call starts with an empty exception stack and a re-entrant one with its caller's; a call is re-entrant iff a host import that may call back is open, which only the host observes on every exit, its glue's finally (host_glue_js); dart has no exception stack.)
function _refuse_imported_global(mod::WasmModule, global_idx::Integer, what::String)::Nothing
    _imported_global(mod, "wasmtarget", "host_imports_open") == global_idx || return nothing
    local g = mod.globals[Int(global_idx) + 1]
    throw(ArgumentError("$what $global_idx names the imported global $(g.module_name).$(g.field_name), " *
                        "not one the program defines"))
end

"""Add a nullable mutable reference global for initialization by a linked root.
parity(quarantine: the substitutions one compilation root carries for a host framework (captured signal globals and constants, a linked root's initializer); dart2wasm compiles one program with one main.)"""
function add_uninitialized_ref_global!(mod::WasmModule, type_idx::Integer)::UInt32
    return add_global!(mod, ConcreteRef(UInt32(type_idx), true), true, nothing)
end

"""
    add_root_global_initializer!(mod, registry, global_idx, root_idx) -> UInt32

Create a module initializer that stores the result of a typed zero-argument
compilation root into a previously declared mutable reference global. Frameworks
use this for exact mutable initial values that cannot appear in a Wasm constant
expression. The initializer joins WT's canonical module-start composition.
parity(quarantine: the substitutions one compilation root carries for a host framework (captured signal globals and constants, a linked root's initializer); dart2wasm compiles one program with one main.)
"""
function add_root_global_initializer!(mod::WasmModule, registry::TypeRegistry,
                                      global_idx::Integer, root_idx::Integer)::UInt32
    0 <= global_idx < length(mod.globals) ||
        throw(ArgumentError("framework global index $global_idx is out of bounds"))
    _refuse_imported_global(mod, global_idx, "framework global index")
    global_def = mod.globals[Int(global_idx) + 1]
    global_def.mutable_ || throw(ArgumentError("framework global $global_idx is immutable"))
    root_type = _function_type(mod, root_idx)
    root_idx >= num_imported_funcs(mod) ||
        throw(ArgumentError("framework initializer root $root_idx is an imported function, not a compiled root"))
    isempty(root_type.params) ||
        throw(ArgumentError("framework initializer root $root_idx must take no parameters"))
    length(root_type.results) == 1 ||
        throw(ArgumentError("framework initializer root $root_idx must return one value"))
    wasm_subtype(only(root_type.results), global_def.valtype, mod.types) ||
        throw(ArgumentError("framework initializer root result is incompatible with global $global_idx"))
    b = InstrBuilder(; func_name="framework_global_initializer", mod=mod)
    call!(b, root_idx)
    global_set!(b, global_idx)
    finish_function!(b)
    # named by the root that computes the value, as dart names a static field's initializer by
    # its member (functions.dart:360); a framework global itself carries no name
    init_idx = add_function!(mod, b;
                             name=generated_function_name(:field_initializer,
                                 mod.functions[Int(root_idx) - num_imported_funcs(mod) + 1].name))
    push!(registry.module_init_functions, init_idx)
    return init_idx
end

"""The one Julia-signature → physical Wasm-signature derivation.
parity(pkg/dart2wasm/lib/translator.dart:1862 Translator.signatureForDirectCall)"""
function function_wasm_signature(arg_types, return_type, global_args,
                                 mod::WasmModule, type_registry::TypeRegistry)::Tuple{Vector{WasmValType}, Vector{WasmValType}}
    pts = WasmValType[]
    for (j, T) in enumerate(arg_types)
        j in global_args && continue
        push!(pts, boundary_wasm_type(T, mod, type_registry))
    end
    rts = (return_type === Nothing || return_type === Union{}) ? WasmValType[] :
          WasmValType[boundary_wasm_type(return_type, mod, type_registry)]
    return pts, rts
end

"""
    boundary_wasm_type(T, mod, registry) -> WasmValType

The wasm type a value of Julia type T has where it crosses a call — a parameter or a result:
a Union that boxes its numbers is anyref; a concrete MemoryRef is its single-value struct
{mem, off0} (register_memoryref_box!), so its element offset crosses with it; anything else
is its concrete wasm type.
parity(sdk/lib/_internal/wasm/common/typed_data.dart:2441 WasmI8ArrayBase): a typed-data view
is an object, passed with its _data and _offsetInElements.
"""
function boundary_wasm_type(@nospecialize(T), mod::WasmModule, type_registry::TypeRegistry)::WasmValType
    T isa Union && needs_anyref_boxing(T) && return AnyRef
    (T isa DataType && T <: Core.GenericMemoryRef && isconcretetype(T)) &&
        return ConcreteRef(register_memoryref_box!(mod, type_registry, T), true)
    return get_concrete_wasm_type(T, mod, type_registry)
end

# ============================================================================
# STANDALONE_INTRINSIC_BODIES — Method-keyed, for entries function_data compiles
# as their OWN body (not a compile_invoke! call-site substitution).
#
# `rethrow`'s native body is itself just a bare `:foreigncall` to
# `jl_rethrow`/`jl_rethrow_other` with no lowering, and Julia's own closed-world
# discovery (collect_closed_world) adds `rethrow`'s MethodInstance to
# function_data as a real entry needing a compiled body whenever ANY reachable
# `:invoke` resolves to it; every such call site is an ordinary cross-call to
# that compiled body. This is common: `try ... finally ... end` nested
# inside an enclosing `catch` lowers to an IMPLICIT `rethrow()` call on the
# exceptional path with no `rethrow` token anywhere in the Julia source
# (confirmed by deleting this arm: a differential test with two nested
# try/finally regions inside a catch failed to compile with no source-text
# `rethrow(` anywhere in the test file). `rethrow()` throws the top of Julia's exception
# stack again (jl_rethrow); `rethrow(e)` first overwrites the top entry's exception with `e`
# (jl_rethrow_other); either, at depth 0, throws Julia's ErrorException (emit_rethrow!).
# ============================================================================
# parity(quarantine: the bespoke bodies L133 allows, each for its stated reason — Base.rethrow's native body is the C runtime's jl_rethrow.)
const STANDALONE_INTRINSIC_BODIES = Dict{Method,Function}()

"""Populate STANDALONE_INTRINSIC_BODIES once, lazily, on first use.
parity(quarantine: the bespoke bodies L133 allows, each for its stated reason — Base.rethrow's native body is the C runtime's jl_rethrow.)"""
function _build_standalone_intrinsic_bodies!()::Nothing
    isempty(STANDALONE_INTRINSIC_BODIES) || return nothing
    for m in methods(Base.rethrow)
        STANDALONE_INTRINSIC_BODIES[m] = _generate_rethrow_standalone_body!
    end
    return nothing
end

"""The one standalone body every `Base.rethrow` MethodInstance compiles to when
function_data needs it as its own entry (see STANDALONE_INTRINSIC_BODIES above): Julia's
jl_rethrow or jl_rethrow_other over the exception stack (emit_rethrow!).
parity(code_generator.dart:2966 visitRethrow): throw the caught exception with the stack trace
its throw captured.
parity(quarantine: Julia's rethrow is a function whose body is a foreigncall to the C
runtime's jl_rethrow, not an expression inside its handler, so it reads the task's exception
stack rather than a handler local.)"""
function _generate_rethrow_standalone_body!(b::InstrBuilder, arg_types::Tuple, mod::WasmModule,
                                            type_registry::TypeRegistry)::InstrBuilder
    if length(arg_types) == 1
        # rethrow(e): `e` overwrites the top entry's exception, thrown with its stack
        _wt_is_ref(b.params[1]) || error("rethrow(e) of a $(arg_types[1]), a value WT does not box " *
                                         "here: its wasm type is $(b.params[1])")
    end
    emit_rethrow!(b, mod, type_registry; other=length(arg_types) == 1 ? 0 : nothing)
    return finish_function!(b)
end

"""Look up whether (f, arg_types) resolves to a Method registered in
STANDALONE_INTRINSIC_BODIES, and if so return the generator that emits its body into the
function's builder, `gen(b, arg_types, mod, type_registry)`.
parity(quarantine: the bespoke bodies L133 allows, each for its stated reason — Base.rethrow's native body is the C runtime's jl_rethrow.)"""
function _standalone_intrinsic_body(f, arg_types::Tuple)::Union{Function,Nothing}
    f isa Function || return nothing
    _build_standalone_intrinsic_bodies!()
    isempty(STANDALONE_INTRINSIC_BODIES) && return nothing
    # Julia's own method lookup, which answers `nothing` for no match or an ambiguity
    hit = p0_uwhich("cp188", Tuple{Core.Typeof(f), arg_types...})
    hit === nothing && return nothing
    return get(STANDALONE_INTRINSIC_BODIES, hit.method, nothing)
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
A stub whose `wasm_idx` is not a host-declared function import (a defined function, or one of
WT's own imports) is refused, naming the stub: its calls would otherwise run whatever function
holds that index.
"""
function _check_import_stub_external_types!(mod::WasmModule, registry::TypeRegistry,
                                             name::AbstractString, arg_types::Tuple,
                                             wasm_idx::Integer, return_type::Type)::Nothing
    local func_imports = filter(imp -> imp.kind == 0x00, mod.imports)
    (0 <= Int(wasm_idx) < length(func_imports) && _is_host_declared_import(func_imports[Int(wasm_idx) + 1])) ||
        throw(ArgumentError("import stub \"$(name)\"$(arg_types) is bound to function index $(wasm_idx), " *
                            "which is not a host-declared function import (the module imports " *
                            "$(length(func_imports)) function(s)): an import_stubs index must name the host import " *
                            "the stub stands for"))
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
Compile a complete closed-world plan (from trim_compile_plan) into one module: register every
function, number the closed world's classes, then emit every body. It never discovers or
silently adds a function.
parity(pkg/dart2wasm/lib/translator.dart:524 Translator.translate)
"""
function _compile_closed_world_plan(plan::ClosedWorldPlan;
                        existing_module::Union{WasmModule, Nothing}=nothing,
                        import_stubs::Vector=[],
                        root_bindings::Dict{String,RootBindings}=Dict{String,RootBindings}(),
                        link_roots::Union{Nothing,Function}=nothing,
                        return_registries::Bool=false,
                        optimize_ir::Bool=true,
                        register_ir_types::Bool=false,
                        source_map_url::Union{Nothing,String}=nothing,
                        trace::Union{Nothing,StatementTrace}=nothing,
                        entry_names::Set{String}=Set{String}(),
                        named_entries::Set{Any}=Set{Any}()
                        )::Union{WasmModule, Tuple{WasmModule, TypeRegistry, FunctionRegistry, DispatchTableRegistry}}
    # This private entry receives only a complete plan produced by
    # `trim_compile_plan`. It never discovers or silently adds functions.
    functions = plan.functions
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
    clear_rng_globals!()
    clear_perf_now!()

    # Create shared module and registries (or use the framework's predeclared module).
    if existing_module !== nothing
        mod = existing_module
        # a module's source map URL is its own, from its construction (dart ModuleBuilder)
        mod.source_map_url == source_map_url || throw(ArgumentError(
            "existing_module records source maps for $(repr(mod.source_map_url)), the compile for " *
            "$(repr(source_map_url)): construct it with WasmModule(; source_map_url)"))
    else
        mod = WasmModule(; source_map_url, builder_trace=OPTIONS[].builder_trace)
    end
    # one module shape: every module can report where its exceptions were thrown, and a
    # source map only maps its code (dart: a throw always captures StackTrace.current). A
    # framework's module declares these imports before its own definitions.
    (existing_module !== nothing && _stack_trace_func_idx(mod) === nothing && !isempty(mod.functions)) &&
        throw(ArgumentError("existing_module defines functions before the imports every module WasmTarget " *
                            "compiles has: call WasmTarget.ensure_provenance_imports!(mod) right after creating it"))
    # a module with a host-declared import imports the count of its open calls, which the host's
    # glue writes (host_glue_js), before any global it defines
    ensure_host_imports_open!(mod)
    ensure_provenance_imports!(mod)
    trace === nothing || ensure_trace_imports!(mod)
    local translator = Translator(plan, trace)
    type_registry = TypeRegistry()
    recover_module_handles!(type_registry, mod)
    append!(type_registry.method_error_args,
            sort!(DataType[T for T in plan.error_args_types if T <: Tuple]; by=type_order_key))
    func_registry = FunctionRegistry()

    # Create base struct type FIRST — all other structs will be subtypes — then the $JlType
    # hierarchy, before any other type registers: every `Any` field, local and signature is
    # anyref, and a type-valued field names its kind's struct.
    # parity(class_info.dart:666 ClassInfoCollector.collect): Top, then `_Type`, before the
    # classes that refer to them.
    get_base_struct_type!(mod, type_registry)
    create_jl_type_hierarchy!(mod, type_registry)

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
            _refuse_imported_global(mod, global_idx, "root $root_name's captured global index")
        end
        for (global_idx, updates) in bindings.dom_bindings
            _refuse_imported_global(mod, global_idx, "root $root_name's DOM binding global index")
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

    # Track all required globals across all functions
    required_globals = Dict{Int, Tuple{WasmValType, Type}}()  # global_idx -> (wasm_type, julia_elem_type)

    # First pass: register types, detect WasmGlobals, and reserve function slots
    # We need to know all function indices before compiling bodies
    # (f, arg_types, name, typed IR, return_type, global_args, is_closure, NIR body) per
    # function — the typed IR only for ir.jl's closed-world type collector; codegen reads
    # the NIR body, built once here
    function_data = []

    for entry in normalized
        f, arg_types, name = entry[1], entry[2], entry[3]
        local entry_mi = length(entry) >= 4 ? entry[4] : nothing
        # Check if this is a closure (function with captured variables)
        # A TYPE-KEYED entry (f IS the closure DataType — capturing
        # closures have no instance) resolves IR by ftype, and the closure type
        # is f itself, not typeof(f).
        local _type_keyed_closure = f isa DataType && is_closure_type(f)
        closure_type = _type_keyed_closure ? f : typeof(f)
        is_closure = is_closure_type(closure_type)

        # the function's typed IR is its MethodInstance's in the collected closed world
        (entry_mi isa Core.MethodInstance && !optimize_ir) &&
            error("unoptimized IR for $f$(arg_types) requested inside a collected closed world, whose IR is optimized")
        entry_mi isa Core.MethodInstance ||
            error("a planned function without its MethodInstance: $(f)$(arg_types)")
        typed, return_type = plan_ir(plan, entry_mi)

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
                              typed === nothing ? nothing : nir_body(typed), entry_mi))
    end

    # Add all required globals to the module
    for global_idx in sort(collect(keys(required_globals)))
        wasm_type, elem_type = required_globals[global_idx]
        _refuse_imported_global(mod, global_idx, "WasmGlobal index")
        while length(mod.globals) <= global_idx
            add_global!(mod, wasm_type, true, zero(elem_type))
        end
    end

    # A foreigncall whose lowering calls the host takes its import here, from the NIR bodies
    # the first pass built: every import precedes the first defined function (add_import!
    # refuses a later one), and the RNG's state globals follow the ones a WasmGlobal argument
    # names by index. rand() reads the Task's Xoshiro state (RNGGlobals, seeded by the host);
    # time_ns() reads the host clock.
    for fd in function_data
        fd[8] === nothing && continue
        for rec in fd[8].stmts
            (rec.slot == 0 && rec.node isa NirForeignCall) || continue
            rec.node.c_symbol === :jl_get_current_task && ensure_rng_globals!(mod)
            rec.node.c_symbol === :jl_hrtime && ensure_perf_now_import!(mod)
        end
    end
    # the first module initializer seeds the RNG's state words from the host
    local _rng = get_rng_globals()
    _rng === nothing || push!(type_registry.module_init_functions, rng_seed_initializer!(mod, _rng))

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

    # Census F2 CLOSE THE TYPE UNIVERSE BEFORE NUMBERING — dart numbers the
    # whole component ONCE, before codegen (class_info.dart:583-690). Walk every
    # function's typed IR and COLLECT every reachable concrete struct / union member
    # so the DFS below numbers the closed world (real [low, high] ranges for isa/
    # typeassert). Collection ONLY — no struct registration: eagerly registering
    # changed field-resolution ORDER and produced duplicate layouts (caught by
    # WasmMakie's E-001); numbering needs no wasm struct to exist, and a type
    # registered lazily later receives its pre-assigned id via ensure_type_id!.
    _reachable = _collect_reachable_ir_types(function_data)
    for (k, vs) in P0_NOMETHOD
        p0!("P0E numbering key_in_reachable=$(k in _reachable) key_in_error_args=$(k in plan.error_args_types)", string(k))
        for v in vs
            p0!("P0E numbering value_in_error_args=$(v in plan.error_args_types)")
        end
    end
    let _vals = Set{Any}(v for vs in values(P0_NOMETHOD) for v in vs)
        local _ea = Set{Any}(T for T in plan.error_args_types if T <: Tuple)
        p0!("P0E numbering tuples_equal=$(_vals == _ea)", _vals == _ea ? "" : "record_only=$(setdiff(_vals, _ea)) flat_only=$(setdiff(_ea, _vals))")
        local _keys = Set{Any}(keys(P0_NOMETHOD))
        local _fs = Set{Any}(T for T in plan.error_args_types if !(T <: Tuple))
        p0!("P0E numbering ftypes_flat_subset_of_keys=$(issubset(_fs, _keys)) keys_subset_flat=$(issubset(_keys, _fs))", "keys_only=$(setdiff(_keys, _fs)) flat_only=$(setdiff(_fs, _keys))")
    end
    # the args tuple of each MethodError a dynamic call throws (the collector's no-method tuples)
    union!(_reachable, plan.error_args_types)
    isempty(plan.error_args_types) || push!(_reachable, MethodError, UInt64)

    # Assign DFS type IDs (the closed world = registered + reachable)
    assign_type_ids!(type_registry; extra_concrete_types=_reachable)

    # Create BoxedNothing singleton global (after type IDs assigned)
    get_nothing_global!(mod, type_registry)

    # Create DataType globals for ALL types with DFS IDs + type lookup table
    ensure_all_type_globals!(mod, type_registry)
    create_type_lookup_table!(mod, type_registry)

    # String hashing needs no pre-created helper function: hash(::String,::UInt)/
    # hash(::SubString{String},::UInt) are overlaid with a pure-Julia,
    # bit-exact-with-native port of the native algorithm (interpreter.jl,
    # "String hash Overlay") that compiles through the ordinary :invoke path
    # like any other Julia function — no special-cased wasm helper needed.

    # Pre-create the shared utf8proc helpers before function-index assignment:
    # category and character width read the same packed property word; case
    # mapping and the case predicates read utf8proc's case records.
    needs_unicode_properties = false
    needs_unicode_case = false
    for fd in function_data
        fn_nir = fd[8]
        fn_nir === nothing && continue
        for rec in fn_nir.stmts
            if rec.slot == 0 && rec.node isa NirForeignCall
                fc_sym = rec.node.c_symbol
                if fc_sym in (:utf8proc_category, :utf8proc_charwidth,
                              :jl_id_start_char, :jl_id_char)
                    needs_unicode_properties = true
                elseif fc_sym in (:utf8proc_toupper, :utf8proc_tolower, :utf8proc_totitle,
                                  :utf8proc_isupper, :utf8proc_islower)
                    needs_unicode_case = true
                end
            end
        end
    end
    needs_unicode_properties && get_or_create_unicode_property_func!(mod, type_registry)
    needs_unicode_case && get_or_create_unicode_case_func!(mod, type_registry)

    # LAZY constants: collect long (>64B) String literals and pre-create their init
    # functions NOW — the same index-freeze constraint (functions cannot be added during
    # body compilation without shifting indices). dart constants.dart:454. A long Symbol
    # literal is built in place (values.jl), so it takes no lazy global.
    for fd in function_data
        fn_nir = fd[8]
        fn_nir === nothing && continue
        for rec in fn_nir.stmts
            for v in nir_literal_values(rec)
                if v isa String && ncodeunits(v) > 64
                    get_or_create_lazy_string!(mod, type_registry, v)
                end
            end
        end
    end

    # Captured variables' types, from the functions that declare them, recorded for every body
    # before any compiles, so no body's box reads depend on which compiled first
    # (record_capture_contents; CaptureType.tla).
    local _capture_bodies = Any[(fd[8].stmts, fd[8].slot_types,
                                 isempty(fd[8].slot_types) ? nothing : fd[8].slot_types[1])
                                for fd in function_data if fd[8] !== nothing]
    merge!(type_registry.box_contents_types,
           record_capture_contents(_capture_bodies; closure_ir=mi -> p0_irget("compile582", plan.ir_cache, mi)))

    # Calculate function indices (accounting for imports + pre-created helper functions)
    # Functions are added in order, so index = n_imports + n_existing + position - 1
    n_imports = length(mod.imports)
    # every function is defined with its signature (function_wasm_signature, the one derivation
    # its body's builder carries too) before any body compiles, so a call! reads every function's
    # type from the moment its index exists: define, then fill (functions.dart:31 define).
    n_existing = length(mod.functions)  # includes pre-created helper functions
    # T1.1 step 2: every dynamic-dispatch candidate (a discovery root, collected first or
    # not) registers as is_candidate=true → visible to the call-site typeId switch (by_ref)
    # and hidden from get_function's signature lookup; an :invoke that names it still
    # reaches it by its MethodInstance (get_function_by_mi).
    _disp_cands = plan.dispatch_candidates
    # each function's name, given where it is defined: its Julia name, with a `_<k>` suffix for
    # the k-th earlier function of that name, the name the compile asks to export it under
    # (codegen_export_name may rename the export in a host's module; a generated function may
    # share the text). A requested name is the entry's own; any other name already given (an
    # entry given without a name, as another specialization of its function is) takes the first
    # free `name_<k>`
    # parity(pkg/dart2wasm/lib/functions.dart:171 FunctionCollector.getFunction): `functions.define(ftype, getFunctionName(target))` names the function where it is defined
    local given_names = Set{String}()
    local plan_names = union(Set{String}(String(fd[3]) for fd in function_data), entry_names)
    local export_name_counts = Dict{String,Int}()
    local defined_names = String[]
    for (f, arg_types, name, _, _, _, _) in function_data
        local export_name = name
        if !((f, Tuple(arg_types)) in named_entries) && (name in given_names || name in entry_names)
            local k = get(export_name_counts, name, 1)
            while string(name, "_", k) in given_names || string(name, "_", k) in plan_names
                k += 1
            end
            export_name = string(name, "_", k)
            export_name_counts[name] = k + 1
        end
        push!(given_names, export_name)
        push!(defined_names, export_name)
    end
    for (i, (f, arg_types, name, _, return_type, global_args, _)) in enumerate(function_data)
        func_idx = UInt32(n_imports + n_existing + i - 1)
        local fd_mi = function_data[i][9]
        # a traced compile traces every function compiled from Julia IR: its id numbers the
        # typed IR its probes report, and the entry's is remembered. A function compiled from
        # a bespoke body (STANDALONE_INTRINSIC_BODIES: rethrow) is not its IR, so it is not
        # traced, and the native run calls it as Julia does
        if trace !== nothing && function_data[i][4] isa Core.CodeInfo && fd_mi isa Core.MethodInstance &&
           !(_build_standalone_intrinsic_bodies!(); fd_mi.def isa Method && haskey(STANDALONE_INTRINSIC_BODIES, fd_mi.def))
            push!(trace.codes, function_data[i][4]); push!(trace.mis, fd_mi)
            push!(trace.probed, Set{Int}())
            trace.ids[func_idx] = length(trace.codes)
            name == trace.entry_name && (trace.entry = length(trace.codes))
        end
        let _old = (!isempty(_disp_cands) && (f, arg_types) in _disp_cands)
            local _cmis = Set{Any}(fn[4] for fn in plan.functions if (fn[1], fn[2]) in _disp_cands)
            local _new = fd_mi in _cmis
            p0!("P0B candidate old=$(_old) by_mi=$(_new)", _old == _new ? "" : "$(name) $(arg_types) $(fd_mi)")
        end
        register_function!(func_registry, name, f, arg_types, func_idx, return_type;
                           is_candidate = (!isempty(_disp_cands) && (f, arg_types) in _disp_cands),
                           mi = fd_mi isa Core.MethodInstance ? fd_mi : nothing,
                           invoke_only = fd_mi in plan.invoke_only)
        # the definition carries the true signature
        local _pp, _rr = try
            function_wasm_signature(arg_types, return_type, global_args, mod, type_registry)
        catch err
            # located at the function whose signature this is, and why it is in the module
            (err isa WasmCompileError || err isa WasmInternalError) && rethrow()
            throw(WasmInternalError(name, 0, "",
                String["declaring the wasm signature of $(name)($(join(("::" * string(T) for T in arg_types), ", "))) -> $(return_type)",
                       "enrolled as " * plan.enrolled_as[fd_mi]],
                err, _raised_frames(catch_backtrace(), :_compile_closed_world_plan)))
        end
        # defined here, its body filled by the compile loop below (every index exists before
        # any body compiles)
        define_function!(mod, _pp, _rr; name=defined_names[i])
    end

    # THE CLOSURE VTABLE PRE-PASS (the index-freeze rule: nothing
    # may add functions during body compilation). Trampolines + vtable globals for
    # every type-keyed userland closure are created NOW; their bodies' FINAL indices
    # are computable deterministically (bodies start after the K trampolines).
    local _cvp = Tuple{Int, DataType, Bool}[] # (function_data position, callable type, takes context)
    for (i, (f, _, _, _, _, _, _)) in enumerate(function_data)
        if f isa DataType && is_closure_type(f)
            push!(_cvp, (i, f, true))
        elseif f isa Function && typeof(f) in plan.callable_types
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
            # a body reached only by `invoke` is no row: dispatch never selects it
            # (an invoke reaches a body Julia's dispatch would not select for its arguments)
            local _mi = _entry[9]
            _mi in plan.invoke_only && continue
            _mi isa Core.MethodInstance && _mi.def isa Method ||
                throw(WasmInternalError(string(_T), 0, "", String["building the vtable of $(_T)"],
                    ErrorException("a callable body with no Method: $(_mi)"), Base.StackTraces.StackFrame[]))
            local _ats, _rt, _gas = _entry[2], _entry[5], _entry[6]
            # the defined functions occupy the body indices already — the standard formula
            # reads them; trampolines append after.
            local _body_idx = UInt32(n_imports + n_existing + _i - 1)
            # the body's own signature, the one its function was defined with: a
            # MemoryRef parameter crosses as its single-value struct, never its bare Memory
            local _bps, _brs = function_wasm_signature(_ats, _rt, _gas, mod, type_registry)
            haskey(_cv_bodies, _T) || (push!(_cv_types, _T); _cv_bodies[_T] = ClosureBody[]; _cv_ctx[_T] = _takes_context)
            push!(_cv_bodies[_T], ClosureBody(_body_idx, _bps, _brs, _rt,
                                              Type[T2 for (j, T2) in enumerate(_ats) if !(j in _gas)], _mi.def))
        end
        for _T in _cv_types
            # a tuple of candidates (the numbered classes and the type objects the program holds)
            # for which Julia's dispatch over two rows' methods is ambiguous is a call Julia
            # rejects: no row order answers it, so the callable rejects (formal(dev/formal/
            # Enrollment.tla): RejectOnlyWhenAmbiguous; an ambiguity no candidate reaches is no
            # reason, AllTypesAmbig). An overlap WT does not enumerate rejects too, ambiguous or
            # not, naming why: the open over-rejection A8C8, BoundIsLoud)
            local _bs = _cv_bodies[_T]
            local _args(c) = _cv_ctx[_T] ? c.julia_params[2:end] : c.julia_params
            for _a in 1:length(_bs), _b in _a+1:length(_bs)
                local _ma, _mb = _bs[_a].method, _bs[_b].method
                (_ma !== _mb && p0_isamb("cp704", _ma, _mb)) || continue
                local _ov = typeintersect(Tuple{_args(_bs[_a])...}, Tuple{_args(_bs[_b])...})
                _ov === Union{} && continue
                local _amb = ambiguous_class_tuple(type_registry, _T, _ov, plan.held_type_objects)
                _amb === false && continue
                throw(WasmCompileError(WasmDiagnostic(:unsupported_method, string(_T),
                    "a dynamic call of $(_T) reaches $(_ma) and $(_mb), which are ambiguous" *
                    (_amb isa String ?
                     ", over an overlap whose candidate tuples WT does not enumerate: $(_amb) (dev/MARCH.md 13.17 A8C8)" :
                     " for ($(join(_amb, ", "))): Julia throws MethodError there"), nothing, nothing)))
            end
            # a candidate taking a bare array whose wasm array type another class shares has no
            # trampoline row a call could be routed by: the callable rejects where its call
            # would trap on that candidate (dev/AUDIT.md A3S2)
            local _shared = bare_array_partition(mod, type_registry, nothing).shared
            for _c in _cv_bodies[_T], _Tj in _c.julia_params
                (_Tj isa DataType && is_bare_array_class(_Tj) &&
                 _Tj in _shared) &&
                    throw(WasmCompileError(WasmDiagnostic(:unsupported_method, string(_T),
                        "a callable with a candidate taking $(_Tj), whose wasm array type another closed-world class shares: no test tells them apart",
                        nothing, nothing)))
                # an abstract parameter admitting a type object or a bare array: no row tests
                # its values' classes (rows per observed class are MARCH 13.17's, A5C4)
                _closure_param_untestable(mod, type_registry, _Tj) &&
                    throw(WasmCompileError(WasmDiagnostic(:unsupported_method, string(_T),
                        "a callable with a candidate taking $(_Tj), which admits a type object or a bare array: no entry row tells its values' classes",
                        nothing, nothing)))
            end
            build_closure_vtable!(mod, type_registry, _T, _cv_bodies[_T]; takes_context=_cv_ctx[_T])
        end
    end

    # the exports a link_roots hook adds belong to this compile too (a framework's host-facing
    # functions): each is exported through its entry below, as the compiler's own are
    local hook_exports_from = length(mod.exports) + 1
    if link_roots !== nothing
        # the linker runs after function indices exist, so add_import! refuses an import from it
        root_indices = Dict{String,UInt32}(
            name => UInt32(n_imports + n_existing + i - 1)
            for (i, (_, _, name, _, _, _, _)) in enumerate(function_data))
        link_roots(mod, root_indices, type_registry)
    end



    # Build dispatch tables for megamorphic functions (>8 specializations)
    # Phase 1: metadata (signatures, globals, tables) — needed by emit_dispatch_call! during body compilation
    dispatch_registry = build_dispatch_tables(func_registry, type_registry)

    if !isempty(dispatch_registry.tables)
        emit_dispatch_metadata!(mod, type_registry, dispatch_registry)
        # parity(dispatch_table.dart:501 DispatchTable.build): pack single-axis selectors into the ONE dart table
        pack_dispatch_selectors!(mod, dispatch_registry, type_registry)
    end

    # the exports this compile makes, (name, function index), one per function it defines:
    # added once, after codegen, where whether the module has Julia's exception stack is known
    local compile_exports = Tuple{String,UInt32}[]

    # Second pass: fill each defined function with its body
    for (i, (f, arg_types, name, _, return_type, global_args, is_closure, fn_nir)) in enumerate(function_data)
        func_idx = UInt32(n_imports + n_existing + i - 1)

        standalone_body = _standalone_intrinsic_body(f, arg_types)
        let _m = function_data[i][9]
            local ka = _m isa Core.MethodInstance && _m.def isa Method && haskey(STANDALONE_INTRINSIC_BODIES, _m.def)
            local kb = standalone_body !== nothing
            local kc = f === Base.rethrow
            p0!("P0C bespoke def_in_table=$ka which_in_table=$kb f_is_rethrow=$kc", (ka == kb == kc) ? "" : "$(f) $(arg_types) $(_m)")
        end

        # Check if this function is a dispatch caller (calls a megamorphic function
        # with abstract args). If so, generate a direct dispatch body instead of the normal body.
        dispatch_dt = nothing
        if fn_nir !== nothing && type_registry.base_struct_idx !== nothing &&
           !isempty(dispatch_registry.tables)
            dispatch_dt = find_dispatch_call(fn_nir.stmts, dispatch_registry)
            # a table with no selector route (three or more varying arguments, an axis tie)
            # makes no dispatch caller: the body compiles from Julia's IR, whose dynamic call
            # dispatches or rejects at its statement
            dispatch_dt !== nothing && !haskey(dispatch_registry.selector_offset, dispatch_dt.func_ref) &&
                (dispatch_dt = nothing)
        end

        # the function's definition, derived once from the plan's MethodInstance for every arm:
        # a whole body maps to it, and a body compiled from IR maps its code outside statements
        # to it (statement 0, map_to_definition!)
        local definition = mod.source_map_url === nothing ? nothing : definition_source_info(function_data[i][9])
        local b::InstrBuilder
        if standalone_body !== nothing || dispatch_dt !== nothing
            # a selector caller's or a standalone intrinsic's body is the body of a Julia method's
            # function, emitted in place of its statements: mapped whole to the method's
            # definition, as dart emits an intrinsic body under its member's offset
            # (code_generator.dart:3625-3634)
            b = function_builder(mod, func_idx)
            definition === nothing || start_source_mapping!(b, definition)
            if standalone_body !== nothing
                standalone_body(b, arg_types, mod, type_registry)
            else
                # Generate dispatch-only body (probe + call_indirect + return)
                # parity(code_generator.dart:2028 CodeGenerator._virtualCall): the dart virtual call — classId + offset + call_indirect
                generate_selector_caller_body!(b, dispatch_dt, dispatch_registry, type_registry.base_struct_idx;
                    caller_return_type=return_type, mod=mod, type_registry=type_registry)
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
                                    translator=translator, func_registry=func_registry, func_idx=func_idx, func_ref=f,
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
            ctx.stmt_sources[0] = definition
            b = generate_body(_ctx_function_builder(ctx, func_idx), ctx)
        end
        fill_function!(mod, func_idx, b)
        push!(compile_exports, (defined_names[i], func_idx))
    end

    # Phase 2: Add wrapper functions AFTER all actual functions are compiled.
    # This ensures entry.target_idx values (from func_registry) point to correct indices.
    if !isempty(dispatch_registry.tables)
        emit_dispatch_wrappers!(mod, type_registry, dispatch_registry)
    end

    # Phase 2: Add overlay wrapper functions

    # Populate DataType/TypeName fields for type constant globals.
    # This creates a start function that patches .name, .super, .parameters, .wrapper.
    fill_egal_function!(mod, type_registry)
    populate_type_constant_globals!(mod, type_registry)
    finalize_module_initializers!(mod, type_registry)
    # an exception that escapes an export leaves Julia's stack as the call found it, so in a
    # module that has the stack an export is its entry ("<export name> (export)"), and the
    # function itself otherwise. A function export this compile's link_roots hook made is
    # retargeted to its entry here, after codegen (dev/MARCH.md 13.17 A13C2, C1); an
    # existing_module's exports, made before this compile, are left as they were made. WT exports
    # every function this compile defines, where dart exports only a member with a wasm:export
    # pragma (functions.dart:154-156): dev/MARCH.md 13.17 A13C3.
    local exc_top = type_registry.handles.exc_top
    if exc_top !== nothing
        for k in hook_exports_from:length(mod.exports)
            local e = mod.exports[k]
            (e.kind == 0x00 && e.idx >= num_imported_funcs(mod)) || continue
            mod.exports[k] = WasmExport(e.name, e.kind, emit_export_entry!(mod, type_registry, e.idx, e.name))
        end
    end
    # an exported function is exported once, under its export name, its entry named by it
    # parity(pkg/dart2wasm/lib/functions.dart:178 exports.export): `module.exports.export(exportName, function)`, once per exported function
    local finals = codegen_export_names(mod, String[first(e) for e in compile_exports], entry_names)
    for ((_, inner_idx), final) in zip(compile_exports, finals)
        add_export!(mod, final, 0, exc_top === nothing ? inner_idx : emit_export_entry!(mod, type_registry, inner_idx, final))
    end
    # the class reader of an escaped exception, over the final numbering, as the egal function's
    # body is filled once codegen has numbered every class
    ensure_class_id_reader!(mod, type_registry, translator)

    # Clear module-level state after compilation
    clear_rng_globals!()
    clear_perf_now!()

    if return_registries
        return (mod, type_registry, func_registry, dispatch_registry)
    end
    return mod
end

# The sole module pipeline: collect one closed world, install its paired typed-IR
# cache for the duration of codegen, then compile that immutable plan. Public
# entry points may normalize inputs, but none may bypass this collector.
# parity(pkg/dart2wasm/lib/compile.dart:572 _runCodegenPhase)
function _compile_module_trim(functions::Vector; kwargs...)::Union{WasmModule, Tuple{WasmModule, TypeRegistry, FunctionRegistry, DispatchTableRegistry}}
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
    # every requested name (an entry given with its name) decided before anything is compiled: a
    # name two entries request, or one entry requested under two names, is refused, never renamed
    # onto another entry; an entry given without a name takes its function's, disambiguated
    local requested = Dict{String,Any}()
    local entry_name = Dict{Any,String}()
    for entry in functions
        length(entry) >= 3 || continue
        local f, arg_types, name = entry[1], entry[2], entry[3]
        local key = (f, Tuple(arg_types))
        local prior = get(requested, name, key)
        isequal(prior, key) || throw(ArgumentError(
            "two entries request the export name \"$name\": $(prior[1])$(prior[2]) and $(f)$(Tuple(arg_types))"))
        local other = get(entry_name, key, name)
        other == name || throw(ArgumentError(
            "the entry $(f)$(Tuple(arg_types)) is requested under two names, \"$other\" and \"$name\""))
        requested[name] = key
        entry_name[key] = name
    end
    kwargs = (; kwargs..., entry_names=Set{String}(keys(requested)), named_entries=Set{Any}(values(requested)))
    try
        return with_layout_read_memo() do
            plan = trim_compile_plan(normalized; external_entries)
            return _compile_closed_world_plan(plan; kwargs...)
        end
    catch err
        # a failure outside any statement — collecting the closed world, registering its
        # types, building its dispatch tables, declaring its functions — located at the
        # module's entries and the compiler frames it was raised through. The caller-facing
        # errors (a rejection, an already-located bug, an invalid module, a misused API) and
        # the process's own (an interrupt, exhausted memory) pass through as they are.
        (err isa WasmCompileError || err isa WasmInternalError || err isa ModuleValidationError ||
         err isa ArgumentError || err isa InterruptException || err isa OutOfMemoryError) && rethrow()
        throw(WasmInternalError(_module_entries_label(normalized), 0, "",
                                String["while planning the module (no statement was being compiled)"],
                                err, _raised_frames(catch_backtrace(), :_compile_module_trim)))
    end
end

# the entries a module compiles, for a failure outside any statement to name
# parity(pkg/dart2wasm/lib/compile.dart:113 CFECrashError)
_module_entries_label(entries::Vector)::String =
    "module of " * join((string(e[3], "(", join(("::" * string(T) for T in e[2]), ", "), ")") for e in entries), ", ")

"""
    compile_module(functions::Vector) -> WasmModule

Compile multiple Julia functions into a single WebAssembly module, unserialized: the closed-world
compile the one compile entry (`_compile`, src/WasmTarget.jl) calls. It is internal to that
entry: it reads the options without setting them and routes no diagnostics ledger, and tests
call it to inspect the module. A compile a caller runs goes through an exported entry
(compile, compile_multi, compile_with_sourcemap, compile_multi_with_sourcemap,
compile_with_statement_trace), each one call of `_compile`.

Each element of `functions` should be a tuple of (function, arg_types) or
(function, arg_types, name). If name is omitted, the function's name is used. Functions can call
each other within the module. It stays exported for the test suite, which inspects the module it
returns; a caller compiles through an exported entry.
parity(pkg/dart2wasm/lib/compile.dart:572 _runCodegenPhase)
"""
function compile_module(functions::Vector;
                        existing_module::Union{WasmModule, Nothing}=nothing,
                        import_stubs::Vector=[],
                        root_bindings::Dict{String,RootBindings}=Dict{String,RootBindings}(),
                        link_roots::Union{Nothing,Function}=nothing,
                        return_registries::Bool=false,
                        optimize_ir::Bool=true,
                        register_ir_types::Bool=false,
                        source_map_url::Union{Nothing,String}=nothing,
                        trace::Union{Nothing,StatementTrace}=nothing)::Union{WasmModule, Tuple{WasmModule, TypeRegistry, FunctionRegistry, DispatchTableRegistry}}
    return _compile_module_trim(functions;
        existing_module, import_stubs, return_registries,
        root_bindings, link_roots, optimize_ir, register_ir_types, source_map_url, trace)
end

# _collect_reachable_ir_types (Phase 12B, the closed-world type collector) lives in
# trimcollect.jl beside the planner; it reads the NIR bodies in `function_data`.

# The names a compile exports its functions under, decided together before any export is made:
# each function's own name (unique in the plan: trim_compile_plan dedups an unrequested name, and
# _compile_module_trim refuses a name two entries request), or, for a name nobody requested that
# the module already exports (a host's existing_module or its link_roots hook), `name_d<k>`, never
# a name already taken or decided. A requested name the module already exports is refused: a
# rename would hand the host another entry's name. The low-level module builder, like dart's
# ExportsBuilder (exports.dart:14), rejects a duplicate name.
# parity(quarantine: a WT invention, open on 13.4's one export namer and 13.17 A13C2/A13C3 — a compile into a host's existing module may be asked for a name that module already exports; dart2wasm builds its module whole, each export name from its member's wasm:export pragma)
function codegen_export_names(mod::WasmModule, names::Vector{String}, requested::Set{String})::Vector{String}
    local taken = Set{String}(e.name for e in mod.exports)
    allunique(names) || error("the plan gave two functions one name: $(names[findfirst(n -> count(==(n), names) > 1, names)])")
    for n in names
        (n in requested && n in taken) && throw(ArgumentError(
            "the module already exports \"$n\", the name this compile is asked to export a function under: " *
            "request another name, or leave the module's export out"))
    end
    local decided = union(taken, Set{String}(names))
    return map(names) do n
        n in taken || return n
        local k = 2
        while string(n, "_d", k) in decided
            k += 1
        end
        push!(decided, string(n, "_d", k))
        return string(n, "_d", k)
    end
end
