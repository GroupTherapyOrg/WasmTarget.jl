() -> begin
    code_inline = "text-accent-500 font-mono"
    code_block = "mt-2 bg-warm-900 dark:bg-warm-950 text-warm-200 p-3 rounded text-xs font-mono overflow-x-auto"
    card = "border border-warm-200 dark:border-warm-800 rounded-lg p-5 space-y-3"

    sections = [
        ("compile", "Core Compilation"),
        ("types", "Types"),
        ("module-building", "Module Building"),
        ("packages", "Package Extensions"),
        ("caching", "Caching"),
        ("source-maps", "Source Maps"),
        ("low-level", "Low-Level / Advanced"),
    ]

    function api_entry(sig, desc)
        Div(:class => card,
            Code(:class => "$code_inline text-sm", sig),
            P(:class => "text-sm text-warm-600 dark:text-warm-400", desc)
        )
    end

    PageWithTOC(sections, Div(:class => "space-y-10",
        H1(:class => "text-3xl font-serif font-bold text-warm-900 dark:text-warm-100", "API Reference"),
        P(:class => "text-warm-600 dark:text-warm-400",
            "Curated overview of the public surface. The full set of exported symbols (including low-level codegen primitives used by Therapy.jl's compiler) is enumerated by ",
            Code(:class => code_inline, "names(WasmTarget)"), "."),

        # ── Core Compilation ──
        H2(:id => "compile", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Core Compilation"),
        api_entry(
            "compile(f, arg_types::Tuple; optimize=false, optimize_ir::Bool=true) -> Vector{UInt8}",
            "Compile a single Julia function for the given concrete argument-type tuple to a self-contained WASM module. \
             The result is a binary `Vector{UInt8}` ready to write to disk and instantiate via `WebAssembly.instantiate`. \
             `optimize=true` runs `wasm-opt` for an ~80–90% size reduction (requires Binaryen)."
        ),
        api_entry(
            "compile_multi(functions::Vector; optimize=false, ...)",
            "Compile multiple `(f, arg_types[, name])` entries into one module. Functions in the same call share the WasmGC \
             type space and can call each other directly — this is the entry point for vector-bridge patterns and any \
             multi-function island."
        ),
        api_entry(
            "compile_from_codeinfo(code_info::Core.CodeInfo, return_type::Type, ...)",
            "Lower-level entry that takes a pre-built `CodeInfo` instead of starting from a function. Used by Therapy.jl's \
             `@island` compiler when it has already computed the IR for a closure body."
        ),
        api_entry(
            "compile_with_base(functions::Vector; ...)",
            "Like `compile_multi` but reuses a shared `Base`-overlay state across the batch. Suitable when compiling many \
             unrelated functions in the same process and the per-call `Base` walk dominates."
        ),
        api_entry(
            "optimize(bytes::Vector{UInt8}) -> Vector{UInt8}",
            "Run Binaryen `wasm-opt` on a previously-compiled module. Same effect as passing `optimize=true` to `compile`."
        ),

        # ── Types ──
        H2(:id => "types", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Types"),
        api_entry(
            "JSValue",
            "Primitive type that maps to WASM `externref`. Use it in function signatures to accept opaque JavaScript \
             handles (DOM elements, JS objects, function references). See the JS Interop section of the Manual."
        ),
        api_entry(
            "WasmGlobal{T, IDX}",
            "Type-safe handle for a WASM global variable at compile-time index `IDX`. Phantom-parameter — `WasmGlobal` \
             arguments do not become WASM function parameters; the compiler emits `global.get` / `global.set` instead. \
             Multiple functions in the same `compile_multi` call share globals."
        ),
        api_entry(
            "WasmModule",
            "Mutable container for hand-built modules: types, functions, imports, exports, tables, memories, data \
             segments. Most users go through `compile` / `compile_multi`; reach for `WasmModule` when you need \
             host-import wiring or custom memory/table layouts."
        ),

        # ── Module Building ──
        H2(:id => "module-building", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Module Building"),
        api_entry(
            "add_import!(mod, module_name, field_name, params, results)",
            "Declare a function the host (JavaScript) must provide. Pure-numeric variants accept `Vector{NumType}`; \
             signatures that include `ExternRef` require `WasmValType[…]` to hit the reference-type overload."
        ),
        api_entry(
            "add_function!(mod, ...) / add_export!(mod, ...)",
            "Append a function to the module and (optionally) export it under a chosen name. The high-level `compile` / \
             `compile_multi` paths call these for you."
        ),
        api_entry(
            "add_global!(mod, ...) / add_global_export!(mod, ...)",
            "Manually add WASM globals — the explicit form behind `WasmGlobal{T, IDX}`. Use when you need named globals \
             or non-default initializers."
        ),
        api_entry(
            "add_table!(mod, reftype::RefType, min, max=nothing)",
            "Add a function-reference or externref table — required for `call_indirect` (multiple-dispatch dynamic \
             dispatch). `reftype` is `FuncRef` or `ExternRef`."
        ),
        api_entry(
            "add_memory!(mod, pages) / add_data_segment!(mod, offset, bytes)",
            "Linear-memory escape hatch. Prefer WasmGC structs/arrays over linear memory for new code."
        ),

        # ── Package Extensions ──
        H2(:id => "packages", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Package Extensions"),
        api_entry(
            "register_package!(mod_name, fns) / list_packages() / package_functions(name)",
            "Register a Julia package's compilable function set with WasmTarget so its overlays + entry-points are \
             discoverable. Powers the auto-discovery that lets a notebook do `using SomePackage` and have its \
             WASM-compatible functions show up automatically."
        ),
        api_entry(
            "compile_with_packages(functions; packages=[…])",
            "Compile against a set of pre-registered packages so their overlays + helper definitions are visible to the \
             Julia compiler before IR extraction."
        ),
        api_entry(
            "register_builtin_packages!() / detect_using_statements(...)",
            "Internal hooks — register WasmTarget's built-in package overlays at module load, and detect `using`/`import` \
             statements in source for auto-registration."
        ),

        # ── Caching ──
        H2(:id => "caching", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Caching"),
        api_entry(
            "compile_cached(f, arg_types; ...) / compile_multi_cached(functions; ...)",
            "Drop-in replacements for `compile` / `compile_multi` that memoize on the input IR + arg types. Returns the \
             cached bytes immediately on hit — useful for hot-reload dev loops and CI builds that compile the same \
             islands repeatedly."
        ),
        api_entry(
            "enable_cache!() / disable_cache!() / clear_cache!() / cache_stats()",
            "Process-wide cache controls. `cache_stats()` returns a NamedTuple of hit/miss counts."
        ),

        # ── Source Maps ──
        H2(:id => "source-maps", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Source Maps"),
        api_entry(
            "compile_with_sourcemap(f, arg_types; ...) / compile_multi_with_sourcemap(functions; ...)",
            "Compile and emit a source-map alongside the WASM bytes so browser DevTools can step through the original \
             Julia line numbers when an exception throws inside a compiled function."
        ),

        # ── Low-Level / Advanced ──
        H2(:id => "low-level", :class => "text-xl font-semibold text-warm-800 dark:text-warm-200", "Low-Level / Advanced"),
        api_entry(
            "to_bytes(mod::WasmModule) -> Vector{UInt8}",
            "Serialize a manually-built `WasmModule` to WASM binary."
        ),
        api_entry(
            "build_frozen_state(...) / FrozenCompilationState",
            "Snapshot of the compilation context (registered types, function table, overlay tables) suitable for reuse \
             across many calls. Therapy.jl uses this between hot-reload iterations."
        ),
        api_entry(
            "TypeRegistry / FunctionRegistry",
            "Mutable registries the compiler walks while lowering IR — types it has seen, functions it has emitted. \
             Exposed for advanced consumers that need to inspect or pre-seed compilation state."
        ),
        api_entry(
            "compile_handler(...) / DOMBindingSpec",
            "Internal hook used by Therapy.jl's `@island` compiler to lower event-handler closures with DOM-binding \
             metadata. Not intended for direct use."
        ),
        P(:class => "text-sm text-warm-500 dark:text-warm-400 pt-4",
            "For codegen primitives (",
            Code(:class => code_inline, "wasm_create_*"), ", ", Code(:class => code_inline, "wasm_set_*"),
            ", IR helpers, etc.) see the source — these are stable between Therapy.jl and WasmTarget.jl but not part of \
             the casual user surface.")
    ))
end
