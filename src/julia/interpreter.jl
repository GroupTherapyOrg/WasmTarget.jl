# The interpreter the closed world is inferred with, WasmTarget's from its own package
# (lib/WasmInterpreter), whose image keeps the Compiler code it specializes, built once per depot and
# never again with WasmTarget's. Each of the package's definitions WasmTarget takes is declared here,
# one binding each, so the registry covers it as any src/julia definition; check_package_declared
# finds the package's definitions exactly these when WasmTarget loads.
# precedent(gpucompiler: CUDA.jl takes its interpreter, method table and cache owner from
# GPUCompiler.jl, a package of their own).

@quarantine "Julia replaces a Base method for one compiler by an overlay method table; WasmTarget's overlays (src/patch) live in the package's" WasmInterpreterPackage.METHOD_TABLE const METHOD_TABLE = WasmInterpreterPackage.METHOD_TABLE

@quarantine "Julia keeps each compiler's inferred code under its own cache owner, so the native cache never holds an overlaid body" WasmInterpreterPackage.WasmCacheOwner const WasmCacheOwner = WasmInterpreterPackage.WasmCacheOwner

@quarantine "Julia folds a call natively only through a method table view that answers isoverlayed false" WasmInterpreterPackage.WasmMethodTable const WasmMethodTable = WasmInterpreterPackage.WasmMethodTable

@quarantine "Julia's inference runs over an AbstractInterpreter; WasmTarget's infers over its overlay table under its cache owner" WasmInterpreterPackage.WasmInterpreter const WasmInterpreter = WasmInterpreterPackage.WasmInterpreter

@quarantine "Julia's trim entry infers a closed world from a queue of roots; the package's runs it over WasmTarget's interpreter" WasmInterpreterPackage.infer_closed_world const infer_closed_world = WasmInterpreterPackage.infer_closed_world
