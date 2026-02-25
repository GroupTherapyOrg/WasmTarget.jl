# ============================================================================
# Main Compilation Entry Point
# ============================================================================

"""
    compile_function(f, arg_types, func_name) -> WasmModule

Compile a Julia function to a WebAssembly module.
"""
function compile_function(f, arg_types::Tuple, func_name::String)::WasmModule
    # Use compile_module for single functions too, enabling auto-discovery of dependencies
    # This ensures that cross-function calls work correctly
    return compile_module([(f, arg_types, func_name)])
end

# Legacy implementation kept for reference - now unused
function _compile_function_legacy(f, arg_types::Tuple, func_name::String)::WasmModule
    # Get typed IR
    code_info, return_type = get_typed_ir(f, arg_types)

    # Create module
    mod = WasmModule()

    # Create type registry for struct mappings
    type_registry = TypeRegistry()

    # Check if this is a closure (function with captured variables)
    # For closures, we need to include the closure object as the first argument
    closure_type = typeof(f)
    is_closure = is_closure_type(closure_type)
    if is_closure
        # Prepend the closure type to arg_types
        arg_types = (closure_type, arg_types...)
    end

    # Detect WasmGlobal arguments (phantom params that map to Wasm globals)
    global_args = Set{Int}()
    for (i, T) in enumerate(arg_types)
        if T <: WasmGlobal
            push!(global_args, i)
            # Add the global to the module at the specified index
            elem_type = global_eltype(T)
            wasm_type = julia_to_wasm_type(elem_type)
            global_idx = global_index(T)
            # Ensure we have enough globals (fill with defaults if needed)
            while length(mod.globals) <= global_idx
                add_global!(mod, wasm_type, true, zero(elem_type))
            end
        end
    end

    # Register any struct/array/string/closure types used in parameters (skip WasmGlobal)
    for (i, T) in enumerate(arg_types)
        if i in global_args
            continue  # Skip WasmGlobal
        end
        if is_closure_type(T)
            # Closure types need special registration
            register_closure_type!(mod, type_registry, T)
        elseif is_struct_type(T)
            register_struct_type!(mod, type_registry, T)
        elseif T <: AbstractArray
            # Register array type for Vector/Matrix parameters
            elem_type = eltype(T)
            get_array_type!(mod, type_registry, elem_type)
        elseif T === String
            # Register string array type
            get_string_array_type!(mod, type_registry)
        end
    end

    # Register return type if it's a struct/array/string
    # Skip Union{} (bottom type) which is a subtype of everything
    if return_type === Union{}
        # Bottom type - no registration needed
    elseif is_struct_type(return_type)
        register_struct_type!(mod, type_registry, return_type)
    elseif return_type <: AbstractArray
        elem_type = eltype(return_type)
        get_array_type!(mod, type_registry, elem_type)
    elseif return_type === String
        get_string_array_type!(mod, type_registry)
    end

    # Determine Wasm types for parameters and return (skip WasmGlobal args)
    param_types = WasmValType[]
    for (i, T) in enumerate(arg_types)
        if !(i in global_args)
            push!(param_types, get_concrete_wasm_type(T, mod, type_registry))
        end
    end
    result_types = (return_type === Nothing || return_type === Union{}) ? WasmValType[] : WasmValType[get_concrete_wasm_type(return_type, mod, type_registry)]

    # For single-function modules, the function index is 0
    # This allows recursive calls to work
    expected_func_idx = UInt32(0)

    # Check if this is an intrinsic function that needs special code generation
    intrinsic_body = is_intrinsic_function(f) ? generate_intrinsic_body(f, arg_types, mod, type_registry) : nothing

    local body::Vector{UInt8}
    local locals::Vector{WasmValType}

    if intrinsic_body !== nothing
        # Use the intrinsic body directly
        body = intrinsic_body
        locals = WasmValType[]  # Intrinsics don't need additional locals
    else
        # Generate function body with the function reference for self-call detection
        ctx = CompilationContext(code_info, arg_types, return_type, mod, type_registry;
                                func_idx=expected_func_idx, func_ref=f, global_args=global_args,
                                is_compiled_closure=is_closure)
        body = generate_body(ctx)
        locals = ctx.locals
    end

    # Add function to module
    func_idx = add_function!(mod, param_types, result_types, locals, body)

    # Export the function
    add_export!(mod, func_name, 0, func_idx)

    # PURE-4149: Populate DataType/TypeName fields for type constant globals
    populate_type_constant_globals!(mod, type_registry)

    return mod
end

# ============================================================================
# WASM-057: Auto-discover function dependencies
# ============================================================================

"""
Set of WasmTarget runtime function names that can be auto-discovered.
These are intrinsic functions that have special compilation support.
"""
const WASMTARGET_RUNTIME_FUNCTIONS = Set([
    # String operations (StringOps.jl)
    :str_char, :str_setchar!, :str_len, :str_new, :str_copy, :str_substr,
    :str_eq, :str_hash, :str_find, :str_contains, :str_startswith, :str_endswith,
    :str_uppercase, :str_lowercase, :str_trim,
    # String conversion (WASM-054, WASM-055)
    :digit_to_str, :int_to_string,
    # Array operations (ArrayOps.jl)
    :arr_new, :arr_get, :arr_set!, :arr_len, :arr_fill!,
    # SimpleDict operations
    :sd_new, :sd_get, :sd_set!, :sd_haskey, :sd_length,
    # StringDict operations
    :sdict_new, :sdict_get, :sdict_set!, :sdict_haskey, :sdict_length,
])

"""
    discover_dependencies(functions::Vector) -> Vector

Scan the IR of all functions and discover WasmTarget runtime function dependencies.
Returns an expanded function list with auto-discovered dependencies added.

This enables calling runtime functions like str_eq without explicitly including them.
"""
function discover_dependencies(functions::Vector)::Vector
    # Normalize input first
    normalized = Vector{Tuple{Any, Tuple, String}}()
    for entry in functions
        if length(entry) == 2
            f, arg_types = entry
            name = string(nameof(f))
            push!(normalized, (f, arg_types, name))
        else
            push!(normalized, (entry[1], entry[2], entry[3]))
        end
    end

    # Track which functions we've already seen (by (func_ref, arg_types))
    seen_funcs = Set{Tuple{Any, Tuple}}()
    for (f, arg_types, _) in normalized
        push!(seen_funcs, (f, arg_types))
    end

    # Track discovered dependencies
    to_add = Vector{Tuple{Any, Tuple, String}}()

    # Queue of functions to scan (using Any-typed vector)
    to_scan = Vector{Tuple{Any, Tuple, String}}(normalized)

    while !isempty(to_scan)
        f, arg_types, name = popfirst!(to_scan)

        # Get IR for this function
        code_info = try
            ir, _ = Base.code_ircode(f, arg_types)[1]
            ir
        catch
            continue  # Skip if we can't get IR
        end

        # Verify we got IRCode (not Method or other types)
        if !hasproperty(code_info, :stmts) || !hasproperty(code_info.stmts, :stmt)
            continue
        end

        # Scan IR for GlobalRef calls to WasmTarget runtime functions
        # Also pass IR + arg_types for :call expression method resolution (PURE-605)
        for (stmt_idx, stmt) in enumerate(code_info.stmts.stmt)
            if stmt isa Expr
                scan_expr_for_deps!(stmt, seen_funcs, to_add, to_scan, code_info, stmt_idx, arg_types)
            end
        end
    end

    # Add discovered dependencies to the function list
    result = copy(normalized)
    append!(result, to_add)
    return result
end

"""
Scan an expression for WasmTarget runtime function calls and external method invocations.
IR context (ir, stmt_idx, func_arg_types) enables :call GlobalRef method resolution (PURE-605).
"""
function scan_expr_for_deps!(expr::Expr, seen_funcs::Set, to_add::Vector, to_scan::Vector,
                             ir=nothing, stmt_idx::Int=0, func_arg_types::Tuple=())
    # Check if this is an invoke expression
    if expr.head === :invoke && length(expr.args) >= 2
        # Check for MethodInstance in args[1] - this enables auto-discovery of external methods
        mi_or_ci = expr.args[1]
        mi = if mi_or_ci isa Core.MethodInstance
            mi_or_ci
        elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
            mi_or_ci.def
        else
            nothing
        end

        if mi !== nothing
            check_and_add_external_method!(mi, seen_funcs, to_add, to_scan)
        end

        # Also check GlobalRef for WasmTarget runtime functions
        func_ref = expr.args[2]
        if func_ref isa GlobalRef
            check_and_add_runtime_func!(func_ref, seen_funcs, to_add, to_scan)
        end
    elseif expr.head === :call && length(expr.args) >= 1
        func_ref = expr.args[1]
        if func_ref isa GlobalRef
            check_and_add_runtime_func!(func_ref, seen_funcs, to_add, to_scan)
            # PURE-605: Try to resolve :call GlobalRef to a method for external modules
            if ir !== nothing
                try_resolve_call_method!(func_ref, expr.args[2:end], ir, func_arg_types,
                                        seen_funcs, to_add, to_scan)
            end
        end
    end

    # Recursively scan nested expressions
    for arg in expr.args
        if arg isa Expr
            scan_expr_for_deps!(arg, seen_funcs, to_add, to_scan)
        end
    end
end

"""
Set of modules whose methods should NOT be auto-discovered and compiled.
These modules contain intrinsics, special handling, or are too complex.
"""
const SKIP_AUTODISCOVER_MODULES = Set([
    :Core,
    :Base,
    :Main,
])

"""
Set of method names that should be skipped during auto-discovery.
These are handled specially in compile_invoke or are error/throw functions.
"""
const SKIP_AUTODISCOVER_METHODS = Set([
    :throw, :rethrow, :ArgumentError, :BoundsError,
    :_throw_argerror, :throw_boundserror,
    :_throw_not_readable, :_throw_not_writable,
    :throw_inexacterror,
    # PURE-605: Builtins that return Method from code_typed, not CodeInfo
    :(===), :isa, :typeof, :ifelse, :throw_boundserror,
])

"""
Set of Base method names that SHOULD be auto-discovered and compiled.
These are methods whose actual Julia implementations we want to compile
to WasmGC rather than intercepting with workarounds.
"""
const AUTODISCOVER_BASE_METHODS = Set{Symbol}([
    :setindex!, :getindex, :ht_keyindex, :ht_keyindex2_shorthash!, :rehash!,
    # PURE-325: String replace operations needed by parse_int_literal
    :_replace_, :_replace_init, :_replace_finish, :take!, :findnext, :unsafe_write,
    # PURE-325: String search operations needed by findnext/replace
    :_search, :first_utf8_byte,
    # PURE-325: Integer parsing needed by parse_int_literal
    :tryparse_internal, :parseint_preamble,
    :iterate_continued, Symbol("#_thisind_continued#_thisind_str##0"),
])

"""
Check if a MethodInstance should be auto-discovered and compiled.
"""
function check_and_add_external_method!(mi::Core.MethodInstance, seen_funcs::Set, to_add::Vector, to_scan::Vector)
    meth = mi.def
    if !(meth isa Method)
        return
    end

    mod = meth.module
    mod_name = nameof(mod)
    meth_name = meth.name

    # Skip core modules - these are handled specially
    # BUT allow whitelisted Base methods (e.g., Dict operations) to be compiled
    if mod_name in SKIP_AUTODISCOVER_MODULES || mod === Core || mod === Base
        if !(mod === Base && meth_name in AUTODISCOVER_BASE_METHODS)
            return
        end
    end

    # Skip error/throw functions
    if meth_name in SKIP_AUTODISCOVER_METHODS
        return
    end

    # Get the function and argument types from the MethodInstance
    func = nothing
    arg_types = nothing

    try
        # Get the function - for constructors, it's the type itself
        sig = mi.specTypes
        if sig <: Tuple && length(sig.parameters) >= 1
            func_type = sig.parameters[1]
            if func_type isa DataType && func_type <: Function
                # Regular function call
                # The function is stored in the Method's sig
                func = getfield(mod, meth_name)
                arg_types = Tuple(sig.parameters[2:end])
            elseif func_type isa DataType && func_type <: Type
                # Constructor call - function is the type
                # e.g., ParseStream(args...) where func_type = Type{ParseStream}
                inner_type = func_type.parameters[1]
                # inner_type can be DataType or UnionAll (for parametric types like Lexer{IO})
                if inner_type isa DataType || inner_type isa UnionAll
                    func = inner_type
                    arg_types = Tuple(sig.parameters[2:end])
                end
            end
        end
    catch
        return  # Can't extract function/types
    end

    if func === nothing || arg_types === nothing
        return
    end

    # PURE-605: Skip kwarg wrapper methods whose arg types contain function singletons
    # (e.g., #untokenize#44 has typeof(untokenize) as a positional arg)
    # These cause cascading discovery of methods that may not compile cleanly.
    # PURE-800: Exempt WasmTarget (M4 self-hosting needs #compile#84)
    # PURE-804: Exempt JuliaSyntax (parsestmt needs #_parse#75)
    # PURE-914: Exempt whitelisted Base methods (findnext takes Fix2{typeof(isequal),Char})
    # Also exempt JuliaSyntax submodules (e.g., Tokenize for accept_number with isdigit)
    _is_julias = nameof(mod) === :JuliaSyntax ||
                 (isdefined(mod, :parentmodule) && try nameof(parentmodule(mod)) === :JuliaSyntax catch; false end)
    _exempt_mod = mod === WasmTarget || _is_julias ||
                  (mod === Base && meth_name in AUTODISCOVER_BASE_METHODS)
    if !_exempt_mod
        for t in arg_types
            if t isa DataType && t <: Function && isconcretetype(t)
                return
            end
        end
    end

    # Create a unique key for this function+types combination
    key = (func, arg_types)
    if key in seen_funcs
        return
    end

    # PURE-605: Verify the function can actually be compiled before adding
    can_compile = try
        ct = Base.code_typed(func, Tuple{arg_types...})
        !isempty(ct) && ct[1][1] isa Core.CodeInfo
    catch
        false
    end
    can_compile || return

    # Add to seen and to_add
    push!(seen_funcs, key)
    name = string(meth_name)
    entry = (func, arg_types, name)
    push!(to_add, entry)
    push!(to_scan, entry)  # Also scan this function for its deps
end

"""
Check if a GlobalRef is a WasmTarget runtime function and add it if needed.
"""
function check_and_add_runtime_func!(ref::GlobalRef, seen_funcs::Set, to_add::Vector, to_scan::Vector)
    # Get the actual function first - this handles cases where the function
    # is imported into another module (e.g., Main.str_eq when using WasmTarget)
    func = try
        getfield(ref.mod, ref.name)
    catch
        return  # Can't get function
    end

    # Skip if not a function
    if !isa(func, Function)
        return
    end

    # Check if this function belongs to WasmTarget (by checking its parent module)
    # This handles both WasmTarget.str_eq and imported str_eq (which becomes Main.str_eq)
    if parentmodule(func) !== WasmTarget
        return
    end

    # Check if this is a known runtime function
    func_name = nameof(func)
    if func_name in WASMTARGET_RUNTIME_FUNCTIONS
        # Determine argument types based on the function name
        arg_types = infer_runtime_func_arg_types(func_name)
        if arg_types === nothing
            return  # Can't infer types
        end

        # Check if we've already seen this (func, arg_types)
        key = (func, arg_types)
        if key in seen_funcs
            return
        end

        # Add to seen and to_add
        push!(seen_funcs, key)
        name = string(func_name)
        entry = (func, arg_types, name)
        push!(to_add, entry)
        push!(to_scan, entry)  # Also scan this function for its deps
    end
end

"""
    PURE-605: Set of modules whose :call GlobalRef expressions should be resolved
    to methods and auto-discovered. Unlike :invoke (which has MethodInstance),
    :call expressions need arg types extracted from IR ssavaluetypes.
"""
const CALL_AUTODISCOVER_MODULES = Set([:JuliaLowering, :JuliaSyntax])

"""
    PURE-605: Whitelisted Base method names for :call auto-discovery.
    These are methods that appear as :call (not :invoke) in lowering IR
    and need to be compiled rather than handled as builtins.
"""
const CALL_AUTODISCOVER_BASE_METHODS = Set([
    :getindex, :setindex!,
])

"""
    _sanitize_ssa_type(t) -> Type

Convert compiler-internal SSA types (PartialStruct, Conditional, MustAlias, etc.)
to concrete DataTypes suitable for `which()` / `Tuple{...}` construction.
"""
function _sanitize_ssa_type(t)
    # Regular types pass through
    t isa Type && return t
    # PartialStruct → use its typ field (the concrete DataType)
    if hasproperty(t, :typ)
        return t.typ
    end
    # Conditional → Bool
    if hasproperty(t, :thentype) && hasproperty(t, :elsetype)
        return Bool
    end
    # Const → typeof the value
    if hasproperty(t, :val)
        return typeof(t.val)
    end
    return Any
end

"""
    try_resolve_call_method!(func_ref, call_args, ir, func_arg_types, seen_funcs, to_add, to_scan)

PURE-605: For :call GlobalRef expressions, try to resolve the method by extracting
argument types from the IR's ssavaluetypes and using `which()` to find the Method.
This handles dynamic calls where Julia couldn't specialize (no MethodInstance in IR).
"""
function try_resolve_call_method!(func_ref::GlobalRef, call_args, ir, func_arg_types::Tuple,
                                  seen_funcs::Set, to_add::Vector, to_scan::Vector)
    mod_name = nameof(func_ref.mod)

    # Only resolve for target modules or whitelisted Base methods
    is_target = mod_name in CALL_AUTODISCOVER_MODULES
    is_base_whitelist = (func_ref.mod === Base && func_ref.name in CALL_AUTODISCOVER_BASE_METHODS)
    (is_target || is_base_whitelist) || return

    # Get the function object
    called_func = try
        getfield(func_ref.mod, func_ref.name)
    catch
        return
    end

    # Skip Core/Base builtins re-exported through JuliaLowering/JuliaSyntax
    # (e.g., JuliaLowering.=== is actually Core.===)
    actual_mod = try parentmodule(called_func) catch; nothing end
    if actual_mod === Core || actual_mod === Base
        # Only allow whitelisted Base methods that should actually be compiled
        if !(actual_mod === Base && func_ref.name in CALL_AUTODISCOVER_BASE_METHODS)
            return
        end
    end

    # Skip builtins/intrinsics that can't be compiled
    (typeof(called_func) <: Core.Builtin || typeof(called_func) <: Core.IntrinsicFunction) && return

    # Extract argument types from IR ssavaluetypes
    # Must sanitize compiler-internal types (PartialStruct, Conditional, etc.) to real Types
    call_types = Any[]
    for arg in call_args
        t = if arg isa Core.SSAValue
            ir.stmts.type[arg.id]
        elseif arg isa Core.Argument
            arg.n >= 1 && arg.n <= length(func_arg_types) ? func_arg_types[arg.n] : Any
        elseif arg isa GlobalRef
            try typeof(getfield(arg.mod, arg.name)) catch; Any end
        else
            typeof(arg)
        end
        # Sanitize compiler-internal types to concrete DataTypes
        push!(call_types, _sanitize_ssa_type(t))
    end

    # Skip if any arg type is a function singleton (kwarg wrapper pattern)
    for t in call_types
        (t isa DataType && t <: Function) && return
    end

    # Try to find a matching method
    arg_tuple = try Tuple{call_types...} catch; return end
    # Try to add the function directly with the inferred arg types
    # Verify it compiles via code_typed first (guards against invalid type combos)
    key = (called_func, Tuple(call_types))
    if key in seen_funcs
        return
    end

    can_compile = try
        ct = Base.code_typed(called_func, arg_tuple)
        !isempty(ct)
    catch
        false
    end

    if can_compile
        push!(seen_funcs, key)
        name = string(func_ref.name)
        entry = (called_func, Tuple(call_types), name)
        push!(to_add, entry)
        # NOTE: Do NOT push to to_scan — :call-discovered functions should not
        # transitively discover more deps. This prevents explosion of the
        # dependency graph into complex JuliaSyntax internals.
    end
end

"""
Infer argument types for WasmTarget runtime functions.
Returns Nothing if types cannot be inferred.
"""
function infer_runtime_func_arg_types(name::Symbol)::Union{Tuple, Nothing}
    # String operations typically use String and Int32
    if name in [:str_char]
        return (String, Int32)
    elseif name in [:str_setchar!]
        return (String, Int32, Int32)
    elseif name in [:str_len]
        return (String,)
    elseif name in [:str_new]
        return (Int32,)
    elseif name in [:str_copy]
        return (String, Int32, String, Int32, Int32)
    elseif name in [:str_substr]
        return (String, Int32, Int32)
    elseif name in [:str_eq, :str_find, :str_contains]
        return (String, String)
    elseif name in [:str_startswith, :str_endswith]
        return (String, String)
    elseif name in [:str_hash]
        return (String,)
    elseif name in [:str_uppercase, :str_lowercase, :str_trim]
        return (String,)
    elseif name in [:digit_to_str]
        return (Int32,)
    elseif name in [:int_to_string]
        return (Int32,)
    # Array operations
    elseif name in [:arr_len]
        return nothing  # Can't infer element type
    elseif name in [:arr_new]
        return nothing  # Can't infer element type
    elseif name in [:arr_get]
        return nothing  # Can't infer element type
    elseif name in [:arr_set!]
        return nothing  # Can't infer element type
    # SimpleDict operations
    elseif name in [:sd_new]
        return (Int32,)
    elseif name in [:sd_get, :sd_haskey]
        return nothing  # Need SimpleDict type
    elseif name in [:sd_set!]
        return nothing  # Need SimpleDict type
    elseif name in [:sd_length]
        return nothing  # Need SimpleDict type
    # StringDict operations
    elseif name in [:sdict_new]
        return (Int32,)
    elseif name in [:sdict_get, :sdict_haskey]
        return nothing  # Need StringDict type
    elseif name in [:sdict_set!]
        return nothing  # Need StringDict type
    elseif name in [:sdict_length]
        return nothing  # Need StringDict type
    else
        return nothing
    end
end

"""
Check if a function is a WasmTarget intrinsic that needs special code generation.
Returns true if the function should be generated as an intrinsic instead of compiling Julia IR.
"""
function is_intrinsic_function(f)::Bool
    # Only functions can be intrinsics, not types (constructors)
    if !(f isa Function)
        return false
    end
    fname = nameof(f)
    return fname in [:str_char, :str_len, :str_eq, :str_new, :str_setchar!, :str_concat, :str_substr]
end

"""
Generate intrinsic function body for WasmTarget runtime functions.
These functions have special WASM implementations that differ from their Julia fallbacks.
Returns the function body bytes, or nothing if not an intrinsic.
"""
function generate_intrinsic_body(f, arg_types::Tuple, mod::WasmModule, type_registry::TypeRegistry)::Union{Vector{UInt8}, Nothing}
    # Only functions can have intrinsic bodies
    if !(f isa Function)
        return nothing
    end
    fname = nameof(f)
    bytes = UInt8[]

    # Get string array type for string operations
    str_type_idx = get_string_array_type!(mod, type_registry)

    if fname === :str_char
        # str_char(s::String, i::Int32)::Int32
        # Gets character at 1-based index
        # local 0 = string (array ref)
        # local 1 = index (i32)
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x00)  # string
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x01)  # index
        # Subtract 1 for 0-based indexing
        push!(bytes, Opcode.I32_CONST)
        push!(bytes, 0x01)
        push!(bytes, Opcode.I32_SUB)
        # array.get
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_GET)
        append!(bytes, encode_leb128_unsigned(str_type_idx))
        push!(bytes, Opcode.END)
        return bytes

    elseif fname === :str_len
        # str_len(s::String)::Int32
        # Returns length of string array
        # local 0 = string (array ref)
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x00)  # string
        # array.len
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_LEN)
        push!(bytes, Opcode.END)
        return bytes

    elseif fname === :str_eq
        # str_eq(a::String, b::String)::Bool
        # Compare two strings character by character
        # This is complex - we need a loop
        # For now, return a simple stub
        # TODO: Implement proper string comparison loop
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x00)  # a
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x01)  # b
        push!(bytes, Opcode.REF_EQ)
        push!(bytes, Opcode.END)
        return bytes

    elseif fname === :str_new
        # str_new(len::Int32)::String
        # Create new string array of given length
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x00)  # length
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
        append!(bytes, encode_leb128_unsigned(str_type_idx))
        push!(bytes, Opcode.END)
        return bytes

    elseif fname === :str_setchar!
        # str_setchar!(s::String, i::Int32, c::Int32)::Nothing
        # Sets character at 1-based index
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x00)  # string
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x01)  # index
        # Subtract 1 for 0-based indexing
        push!(bytes, Opcode.I32_CONST)
        push!(bytes, 0x01)
        push!(bytes, Opcode.I32_SUB)
        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x02)  # char
        # array.set
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_SET)
        append!(bytes, encode_leb128_unsigned(str_type_idx))
        push!(bytes, Opcode.END)
        return bytes

    elseif fname === :str_substr
        # str_substr(s::String, start::Int32, len::Int32)::String
        # Extracts substring by creating new string and copying characters
        # local 0 = source string (array ref)
        # local 1 = start (1-based Int32)
        # local 2 = len (Int32)

        # NOTE: The inline version at call sites properly implements this using
        # array.new + array.copy with scratch locals from the caller's context.
        # This intrinsic body is only used when str_substr is called as a
        # standalone function. We return a stub that returns the source string.
        # The proper implementation requires extra locals which intrinsics don't support.

        push!(bytes, Opcode.LOCAL_GET)
        push!(bytes, 0x00)  # return source string as placeholder
        push!(bytes, Opcode.END)
        return bytes
    end

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
function compile_module(functions::Vector; stub_names::Set{String}=Set{String}())::WasmModule
    # WASM-057: Auto-discover function dependencies
    functions = discover_dependencies(functions)
    # Create shared module and registries
    mod = WasmModule()
    type_registry = TypeRegistry()
    func_registry = FunctionRegistry()

    # WASM-060: Add Math.pow import for float power operations
    # This enables x^y for Float32/Float64 types
    add_import!(mod, "Math", "pow", NumType[F64, F64], NumType[F64])

    # PURE-325: Pre-register numeric box types for all common numeric Wasm types.
    # These are needed when functions with ExternRef return types (heterogeneous Unions)
    # need to return numeric values. Pre-registering avoids compilation order issues
    # where the caller's isa() check is compiled before the callee's box type exists.
    for nt in (I32, I64, F32, F64)
        get_numeric_box_type!(mod, type_registry, nt)
    end

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

    # Track all required globals across all functions
    required_globals = Dict{Int, Tuple{WasmValType, Type}}()  # global_idx -> (wasm_type, julia_elem_type)

    # First pass: register types, detect WasmGlobals, and reserve function slots
    # We need to know all function indices before compiling bodies
    function_data = []  # Store (f, arg_types, name, code_info, return_type, global_args) for each function

    for (f, arg_types, name) in normalized
        # Check if this is a closure (function with captured variables)
        closure_type = typeof(f)
        is_closure = is_closure_type(closure_type)
        if is_closure
            # Prepend the closure type to arg_types
            arg_types = (closure_type, arg_types...)
        end

        # Get typed IR
        code_info, return_type = get_typed_ir(f, arg_types)

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

        # Register types used in parameters (skip WasmGlobal)
        for (i, T) in enumerate(arg_types)
            if i in global_args
                continue
            end
            if is_closure_type(T)
                register_closure_type!(mod, type_registry, T)
            elseif T === Symbol
                # Symbol is represented as a string (byte array), not a struct
                get_string_array_type!(mod, type_registry)
            elseif is_struct_type(T)
                register_struct_type!(mod, type_registry, T)
            elseif T <: Array
                # Vector/Array is now a struct with (ref, size) for setfield! support
                register_vector_type!(mod, type_registry, T)
            elseif T <: AbstractVector && T isa DataType
                # Other AbstractVector types (SubArray, UnitRange, etc.) - register as regular struct
                register_struct_type!(mod, type_registry, T)
            elseif T <: AbstractArray
                # Multi-dimensional arrays (Matrix, etc.) - register as struct
                register_matrix_type!(mod, type_registry, T)
            elseif T === String
                get_string_array_type!(mod, type_registry)
            end
        end

        # Register return type
        if is_closure_type(return_type)
            register_closure_type!(mod, type_registry, return_type)
        elseif return_type === Symbol
            # Symbol is represented as a string (byte array), not a struct
            get_string_array_type!(mod, type_registry)
        elseif is_struct_type(return_type)
            register_struct_type!(mod, type_registry, return_type)
        elseif return_type !== Union{} && return_type <: Array
            # Vector/Array is now a struct with (ref, size) for setfield! support
            register_vector_type!(mod, type_registry, return_type)
        elseif return_type !== Union{} && return_type <: AbstractVector && return_type isa DataType
            # Other AbstractVector types (SubArray, UnitRange, etc.) - register as regular struct
            register_struct_type!(mod, type_registry, return_type)
        elseif return_type !== Union{} && return_type <: AbstractArray
            # Multi-dimensional arrays (Matrix, etc.) - register as struct
            register_matrix_type!(mod, type_registry, return_type)
        elseif return_type === String
            get_string_array_type!(mod, type_registry)
        end

        push!(function_data, (f, arg_types, name, code_info, return_type, global_args, is_closure))
    end

    # Add all required globals to the module
    for global_idx in sort(collect(keys(required_globals)))
        wasm_type, elem_type = required_globals[global_idx]
        while length(mod.globals) <= global_idx
            add_global!(mod, wasm_type, true, zero(elem_type))
        end
    end

    # Scan all function IR for GlobalRef to mutable structs (module-level globals)
    # These need to be shared across all functions as WASM globals
    module_globals = Dict{Tuple{Module, Symbol}, UInt32}()
    for (f, arg_types, name, code_info, return_type, global_args, is_closure) in function_data
        for stmt in code_info.code
            if stmt isa GlobalRef
                # Check if this GlobalRef points to a mutable struct instance
                try
                    actual_val = getfield(stmt.mod, stmt.name)
                    T = typeof(actual_val)
                    # Check if it's a mutable struct (but not a type, function, or module)
                    if ismutabletype(T) && !isa(actual_val, Type) && !isa(actual_val, Function) && !isa(actual_val, Module)
                        key = (stmt.mod, stmt.name)
                        if !haskey(module_globals, key)
                            # Register the struct type first
                            info = register_struct_type!(mod, type_registry, T)
                            type_idx = info.wasm_type_idx

                            # Build initialization expression: struct.new with default values
                            init_bytes = UInt8[]
                            for field_name in fieldnames(T)
                                field_val = getfield(actual_val, field_name)
                                append!(init_bytes, compile_const_value(field_val, mod, type_registry))
                            end
                            push!(init_bytes, Opcode.GC_PREFIX)
                            push!(init_bytes, Opcode.STRUCT_NEW)
                            append!(init_bytes, encode_leb128_unsigned(type_idx))

                            # Add global with reference type
                            global_idx = add_global_ref!(mod, type_idx, true, init_bytes; nullable=false)
                            module_globals[key] = global_idx
                        end
                    end
                catch
                    # If we can't evaluate, skip it
                end
            end
        end
    end

    # Calculate function indices (accounting for imports)
    # Functions are added in order, so index = n_imports + position - 1
    n_imports = length(mod.imports)
    for (i, (f, arg_types, name, _, return_type, _, _)) in enumerate(function_data)
        func_idx = UInt32(n_imports + i - 1)
        register_function!(func_registry, name, f, arg_types, func_idx, return_type)
    end

    # Track export names to avoid duplicates (WASM requires unique export names)
    export_name_counts = Dict{String, Int}()

    # Second pass: compile function bodies
    for (i, (f, arg_types, name, code_info, return_type, global_args, is_closure)) in enumerate(function_data)
        func_idx = UInt32(n_imports + i - 1)
        # Check if this is an intrinsic function that needs special code generation
        intrinsic_body = is_intrinsic_function(f) ? generate_intrinsic_body(f, arg_types, mod, type_registry) : nothing

        local body::Vector{UInt8}
        local locals::Vector{WasmValType}

        if name in stub_names
            # PURE-6024: Emit unreachable stub for functions that should not be compiled
            # (e.g. optimization pass functions eliminated by may_optimize=false).
            # The function exists as a valid call target but traps if ever called.
            body = UInt8[Opcode.UNREACHABLE, Opcode.END]
            locals = WasmValType[]
        elseif intrinsic_body !== nothing
            # Use the intrinsic body directly
            body = intrinsic_body
            locals = WasmValType[]  # Intrinsics don't need additional locals
        else
            # Generate function body from Julia IR
            ctx = CompilationContext(code_info, arg_types, return_type, mod, type_registry;
                                    func_registry=func_registry, func_idx=func_idx, func_ref=f,
                                    global_args=global_args, is_compiled_closure=is_closure,
                                    module_globals=module_globals)
            body = generate_body(ctx)
            locals = ctx.locals
        end

        # Get param/result types (skip WasmGlobal args)
        param_types = WasmValType[]
        for (j, T) in enumerate(arg_types)
            if !(j in global_args)
                push!(param_types, get_concrete_wasm_type(T, mod, type_registry))
            end
        end
        result_types = (return_type === Nothing || return_type === Union{}) ? WasmValType[] : WasmValType[get_concrete_wasm_type(return_type, mod, type_registry)]

        # Add function to module
        actual_idx = add_function!(mod, param_types, result_types, locals, body)

        # Export the function with a unique name
        export_name = name
        count = get(export_name_counts, name, 0)
        if count > 0
            export_name = "$(name)_$(count)"
        end
        export_name_counts[name] = count + 1
        add_export!(mod, export_name, 0, actual_idx)
    end

    # PURE-4149: Populate DataType/TypeName fields for type constant globals.
    # This creates a start function that patches .name, .super, .parameters, .wrapper.
    populate_type_constant_globals!(mod, type_registry)

    return mod
end

"""
    compile_module_from_ir(ir_entries::Vector)::WasmModule

Compile pre-computed typed CodeInfo entries to a WasmModule, bypassing Base.code_typed().
Each entry is (code_info::CodeInfo, return_type::Type, arg_types::Tuple, name::String).

This is the entry point for the eval_julia pipeline where type inference has already been run.
Unlike compile_module, this does NOT call get_typed_ir() or discover_dependencies().
"""
function compile_module_from_ir(ir_entries::Vector)::WasmModule
    mod = WasmModule()
    type_registry = TypeRegistry()
    func_registry = FunctionRegistry()

    # Add Math.pow import (same as compile_module)
    add_import!(mod, "Math", "pow", NumType[F64, F64], NumType[F64])

    # Pre-register numeric box types (same as compile_module)
    for nt in (I32, I64, F32, F64)
        get_numeric_box_type!(mod, type_registry, nt)
    end

    # Build function_data from pre-computed IR (no get_typed_ir call)
    function_data = []
    for (code_info, return_type, arg_types, name) in ir_entries
        global_args = Set{Int}()

        # Register types used in parameters
        for (i, T) in enumerate(arg_types)
            if T === Symbol
                get_string_array_type!(mod, type_registry)
            elseif is_struct_type(T)
                register_struct_type!(mod, type_registry, T)
            elseif T <: Array
                register_vector_type!(mod, type_registry, T)
            elseif T === String
                get_string_array_type!(mod, type_registry)
            end
        end

        # Register return type
        if is_struct_type(return_type)
            register_struct_type!(mod, type_registry, return_type)
        elseif return_type !== Union{} && return_type <: Array
            register_vector_type!(mod, type_registry, return_type)
        elseif return_type === String
            get_string_array_type!(mod, type_registry)
        end

        push!(function_data, (nothing, arg_types, name, code_info, return_type, global_args, false))
    end

    # Scan for GlobalRef to mutable structs (same as compile_module)
    module_globals = Dict{Tuple{Module, Symbol}, UInt32}()
    for (_, _, _, code_info, _, _, _) in function_data
        for stmt in code_info.code
            if stmt isa GlobalRef
                try
                    actual_val = getfield(stmt.mod, stmt.name)
                    T = typeof(actual_val)
                    if ismutabletype(T) && !isa(actual_val, Type) && !isa(actual_val, Function) && !isa(actual_val, Module)
                        key = (stmt.mod, stmt.name)
                        if !haskey(module_globals, key)
                            info = register_struct_type!(mod, type_registry, T)
                            type_idx = info.wasm_type_idx
                            init_bytes = UInt8[]
                            for field_name in fieldnames(T)
                                field_val = getfield(actual_val, field_name)
                                append!(init_bytes, compile_const_value(field_val, mod, type_registry))
                            end
                            push!(init_bytes, Opcode.GC_PREFIX)
                            push!(init_bytes, Opcode.STRUCT_NEW)
                            append!(init_bytes, encode_leb128_unsigned(type_idx))
                            global_idx = add_global_ref!(mod, type_idx, true, init_bytes; nullable=false)
                            module_globals[key] = global_idx
                        end
                    end
                catch
                end
            end
        end
    end

    # Calculate function indices
    n_imports = length(mod.imports)
    for (i, (f, arg_types, name, _, return_type, _, _)) in enumerate(function_data)
        func_idx = UInt32(n_imports + i - 1)
        register_function!(func_registry, name, f, arg_types, func_idx, return_type)
    end

    # Compile function bodies
    export_name_counts = Dict{String, Int}()
    for (i, (f, arg_types, name, code_info, return_type, global_args, is_closure)) in enumerate(function_data)
        func_idx = UInt32(n_imports + i - 1)

        # Generate function body from Julia IR (no intrinsic check — pre-computed IR is always normal code)
        ctx = CompilationContext(code_info, arg_types, return_type, mod, type_registry;
                                func_registry=func_registry, func_idx=func_idx, func_ref=nothing,
                                global_args=global_args, is_compiled_closure=false,
                                module_globals=module_globals)
        body = generate_body(ctx)
        locals = ctx.locals

        # Get param/result types
        param_types = WasmValType[]
        for (j, T) in enumerate(arg_types)
            push!(param_types, get_concrete_wasm_type(T, mod, type_registry))
        end
        result_types = (return_type === Nothing || return_type === Union{}) ? WasmValType[] : WasmValType[get_concrete_wasm_type(return_type, mod, type_registry)]

        # Add function to module
        actual_idx = add_function!(mod, param_types, result_types, locals, body)

        # Export
        export_name = name
        count = get(export_name_counts, name, 0)
        if count > 0
            export_name = "$(name)_$(count)"
        end
        export_name_counts[name] = count + 1
        add_export!(mod, export_name, 0, actual_idx)
    end

    populate_type_constant_globals!(mod, type_registry)
    return mod
end

"""
Specification for a DOM update call after signal write.
Used by compile_handler to inject DOM update calls after signal writes.
"""
struct DOMBindingSpec
    import_idx::UInt32          # Index of the DOM import function
    const_args::Vector{Int32}   # Constant arguments (e.g., hydration key)
    include_signal_value::Bool  # Whether to pass signal value as final arg
end

"""
    compile_handler(closure, signal_fields, export_name; globals, imports, dom_bindings) -> WasmModule

Compile a Therapy.jl event handler closure to WebAssembly with signal substitution.

The `signal_fields` dict maps captured closure field names to their signal info:
- Key: field name (Symbol), e.g., :count, :set_count
- Value: tuple (is_getter::Bool, global_idx::UInt32, value_type::Type)

The handler closure should take no arguments. Signal getters/setters are captured
in the closure and compiled to Wasm global.get/global.set operations.

When `dom_bindings` is provided, DOM update calls are automatically injected after
each signal write. This is used by Therapy.jl for reactive DOM updates.

# Example
```julia
count, set_count = create_signal(0)
handler = () -> set_count(count() + 1)

signal_fields = Dict(
    :count => (true, UInt32(0), Int64),      # getter for global 0
    :set_count => (false, UInt32(0), Int64)  # setter for global 0
)

mod = compile_handler(handler, signal_fields, "onclick")
```
"""
function compile_handler(
    closure::Function,
    signal_fields::Dict{Symbol, Tuple{Bool, UInt32, Type}},
    export_name::String;
    globals::Vector{Tuple{Type, Any}} = Tuple{Type, Any}[],  # (type, initial_value) pairs
    imports::Vector{Tuple{String, String, Vector, Vector}} = Tuple{String, String, Vector, Vector}[],  # (module, name, params, results)
    dom_bindings::Dict{UInt32, Vector{DOMBindingSpec}} = Dict{UInt32, Vector{DOMBindingSpec}}()  # global_idx -> DOM updates
)::WasmModule
    # Get typed IR for the closure (no arguments since it's a thunk)
    typed_results = Base.code_typed(closure, ())
    if isempty(typed_results)
        error("Could not get typed IR for handler closure")
    end
    code_info, return_type = typed_results[1]

    # Create module
    mod = WasmModule()
    type_registry = TypeRegistry()

    # Add imports first (they affect function indices)
    import_indices = Dict{Tuple{String, String}, UInt32}()
    for (mod_name, func_name, params, results) in imports
        idx = add_import!(mod, mod_name, func_name, params, results)
        import_indices[(mod_name, func_name)] = idx
    end

    # Create globals from signal fields
    # Collect unique global indices and their types
    required_globals = Dict{UInt32, Type}()
    for (_, (_, global_idx, value_type)) in signal_fields
        if !haskey(required_globals, global_idx)
            required_globals[global_idx] = value_type
        end
    end

    # Add explicit globals passed in
    for (i, (gtype, gval)) in enumerate(globals)
        global_idx = UInt32(i - 1)
        if !haskey(required_globals, global_idx)
            required_globals[global_idx] = gtype
        end
    end

    # Add all required globals to the module and export them
    for global_idx in sort(collect(keys(required_globals)))
        value_type = required_globals[global_idx]
        wasm_type = julia_to_wasm_type(value_type)
        # Find initial value from explicit globals if available
        initial_value = zero(value_type)
        if Int(global_idx) + 1 <= length(globals)
            _, initial_value = globals[Int(global_idx) + 1]
        end
        while length(mod.globals) <= Int(global_idx)
            actual_idx = add_global!(mod, wasm_type, true, initial_value)
            # Export the global for JS access
            add_global_export!(mod, "signal_$(actual_idx)", actual_idx)
        end
    end

    # Build captured_signal_fields for CompilationContext
    # Maps field_name -> (is_getter, global_idx) without the type
    captured_signal_fields = Dict{Symbol, Tuple{Bool, UInt32}}()
    for (field_name, (is_getter, global_idx, _)) in signal_fields
        captured_signal_fields[field_name] = (is_getter, global_idx)
    end

    # Convert DOMBindingSpec to internal format for CompilationContext
    # Internal format: global_idx -> [(import_idx, const_args), ...]
    internal_dom_bindings = Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}()
    for (global_idx, specs) in dom_bindings
        internal_dom_bindings[global_idx] = [(spec.import_idx, spec.const_args) for spec in specs]
    end

    # Compile the closure body
    # Closures have one implicit argument (_1 = self)
    ctx = CompilationContext(
        code_info,
        (),  # No explicit arguments
        return_type,
        mod,
        type_registry;
        captured_signal_fields = captured_signal_fields,
        dom_bindings = internal_dom_bindings
    )
    body = generate_body(ctx)

    # Handler functions take no params and return nothing (void)
    # The return value (if any) is typically dropped in event handlers
    param_types = WasmValType[]
    result_types = WasmValType[]  # Event handlers return void

    # Add function to module
    func_idx = add_function!(mod, param_types, result_types, ctx.locals, body)

    # Export the function
    add_export!(mod, export_name, 0, func_idx)

    return mod
end

"""
    compile_closure_body(closure, captured_signal_fields, mod, type_registry; dom_bindings) -> (Vector{UInt8}, Vector{NumType})

Compile a closure body to Wasm bytecode without creating a new module.
Returns the body bytecode and locals needed for the function.

This is the lower-level API used by Therapy.jl to compile handler closures
into an existing module with shared globals and imports.

The `captured_signal_fields` maps field names to (is_getter, global_idx).
The `dom_bindings` maps global_idx to list of (import_idx, const_args) tuples.
"""
function compile_closure_body(
    closure::Function,
    captured_signal_fields::Dict{Symbol, Tuple{Bool, UInt32}},
    mod::WasmModule,
    type_registry::TypeRegistry;
    dom_bindings::Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}} = Dict{UInt32, Vector{Tuple{UInt32, Vector{Int32}}}}(),
    void_return::Bool = false
)
    # Get typed IR for the closure
    typed_results = Base.code_typed(closure, ())
    if isempty(typed_results)
        error("Could not get typed IR for handler closure")
    end
    code_info, inferred_return_type = typed_results[1]

    # For void handlers (like Therapy.jl event handlers), override return type
    return_type = void_return ? Nothing : inferred_return_type

    # Create compilation context
    ctx = CompilationContext(
        code_info,
        (),  # No explicit arguments
        return_type,
        mod,
        type_registry;
        captured_signal_fields = captured_signal_fields,
        dom_bindings = dom_bindings
    )

    # Generate body
    body = generate_body(ctx)

    return (body, ctx.locals)
end

