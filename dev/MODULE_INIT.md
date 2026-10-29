# Module initialization: which `__init__` a compiled program runs, and when

The lead's ruling of 2026-10-29 on item (c) of the lazy static fields. The sources cited are Julia 1.12.7's
own: `base/` and `juliac/` under `share/julia`, and the C runtime at the tag `v1.12.7`.

## What juliac's trimmed image runs at startup

- Every module goes on the init list when its definition finishes, so a submodule goes before its
  parent (`src/toplevel.c:207-209`). While output is being built, none of them runs (`:215`).
- A package restored while juliac builds a system image is put on that same list, not run
  (`base/loading.jl:1432` loops the image's `inits`, `:1443` `run_module_init` calls
  `jl_init_restored_module`, `src/module.c:2085`, which defers through `jl_add_to_module_init_list`,
  `:2075`).
- The base image's list never ran in the build process either (`src/init.c:618`), so Base and its
  submodules stay on it. `juliac/juliac-buildscript.jl:6-10` calls `Sys.__init__`, `reinit_stdio` and the
  depot and load path setup by hand for that reason.
- At output, every module on the list that has an `__init__` stays in the order. Under `--trim`, each
  such `__init__` is added as an entrypoint of the trim inference (`src/precompile.c:111-141`,
  `jl_add_entrypoint`), which `typeinf_ext_toplevel` infers and verifies
  (`Compiler/src/typeinfer.jl:1534`). The list is saved in the image (`src/staticdata.c:276`).
- At startup, `src/init.c:618-628` runs the saved list in order, and `jl_module_run_initializer`
  (`src/toplevel.c:57`) calls a module's `__init__` when it has one.
- So trim does keep `Base.__init__`. It verifies only because juliac rewrites what fails in it:
  `reinit_stdio`, `init_active_project` and `start_profile_listener` become stubs, and `Base.GMP.__init__`
  is rewritten (`juliac/juliac-trim-base.jl:11-20`, `:147`). Stdlib initializers that don't trim are
  rewritten too, Pkg's to `rand()` ("methods that do nothing don't get codegened",
  `juliac/juliac-trim-stdlib.jl:56`).

## What Base's `__init__` does

`base/Base.jl:368`:

- Runtime and host setup: `Filesystem.__postinit__`, `reinit_stdio`, `Multimedia.reinit_displays`, the
  depot path, load path and active project, `start_profile_listener`, `ENV`'s Tracy entry, and
  `JuliaSyntax.enable_in_core!`.
- Julia-visible state it sets, which a program can read: `_atexit_hooks_finished`, `stdout`, `stdin`,
  `stderr`, `Multimedia.displays`, `DEPOT_PATH`, `LOAD_PATH`, `ACTIVE_PROJECT`, `_sysimage_modules`,
  `loaded_precompiles`, `MAX_NUM_PRECOMPILE_FILES`, `_require_world_age`, and the global logger
  (`CoreLogging.global_logger(ConsoleLogger())`).
- Base's submodules initialize themselves too: `Sys` (`base/sysinfo.jl:150`, which sets
  `Sys.CPU_THREADS` among others), `GMP` (`base/gmp.jl:108`), `MPFR` (`base/mpfr.jl:46`), and one in
  `base/experimental.jl:266`.
- Every piece goes through foreigncalls: `ccall`, `dlopen` and libuv. In WasmTarget's subset a
  foreigncall is a host import (dev/MARCH.md 1.F).

## The ruling

1. **Core and Base are the runtime's.** WasmTarget compiles no `__init__` of a module whose
   `parentmodule` chain reaches `Core` or `Base`. Their dart2wasm counterpart is the JS runtime and the
   embedder's setup, which run outside the compiled program.
   - A binding of such a module that is non-const, or const but mutable, gets a located rejection
     naming "Base.__init__ (the runtime's)". The rule goes by module, not by reading code.
2. **Every other module the closed world reaches has its `__init__` compiled into the start
   function.** A module is reached when a method of the closed world was defined in it, or a body
   reads or writes one of its bindings.
   - Each such `__init__` is a root of the one trim inference beside the entry, as
     `src/precompile.c:136` makes it. An `__init__` outside the strict subset is rejected by Julia's
     verifier, located at that `__init__`.
   - Roots are added until no new module is reached.
3. **Order.** Root modules follow `Base.loaded_modules_order`. Within one root, a submodule's
   `__init__` runs before its parent's, Julia's definition-finished order (`src/toplevel.c:207`).
   - Julia keeps no order between two sibling modules once their definitions have run: the session
     consumed the list (`src/toplevel.c:215-230`).
   - So two reached sibling modules that both have an `__init__` are a located rejection naming
     both. WasmTarget never invents an order for them.
4. **After this, a lazy static field's initializer is sound.** Its value is the binding's image value,
   instantiated through Constants (`===`-canonical). Each module's `__init__` writes through the field's
   setter in the start function, as juliac's startup does.

## Known deviations from juliac

- (i) juliac runs the `__init__` of every module on the image's list. WasmTarget runs only those of
  the modules the closed world reaches. So an unreached module whose `__init__` writes a reached
  module's binding is not run.
  - Compiling every loaded module instead would make a compile depend on what the session has
    loaded (Test, Pkg).
  - The start-function pass carries a `@quarantine` naming this deviation.
- (ii) A reached stdlib's `__init__` that does not verify is a located rejection. juliac would have
  rewritten it (`juliac/juliac-trim-stdlib.jl`). WasmTarget verifies over unmodified Base and stdlibs
  (dev/LEDGER.md D32).
