# API Reference

## Core Compilation

```@docs
compile
compile_multi
compile_from_codeinfo
compile_with_base
optimize
```

## Types

```@docs
JSValue
WasmGlobal
WasmModule
```

## Module Building

```@docs
add_import!
add_function!
add_export!
add_global!
add_global_export!
```

## Package Extensions

```@docs
register_package!
list_packages
package_functions
compile_with_packages
```

## Caching

```@docs
compile_cached
compile_multi_cached
enable_cache!
disable_cache!
clear_cache!
cache_stats
```

## Source Maps

```@docs
compile_with_sourcemap
compile_multi_with_sourcemap
```

## Low-Level / Advanced

```@docs
to_bytes
FrozenCompilationState
build_frozen_state
TypeRegistry
FunctionRegistry
compile_handler
DOMBindingSpec
```
