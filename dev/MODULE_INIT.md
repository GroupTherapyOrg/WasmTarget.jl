# Module initialization: which `__init__` a compiled program runs

The lead's ruling of 2026-10-29 on item (c) of the lazy static fields, replacing the first ruling of
the same day, which would have compiled each reached module's `__init__` into the start function. The
sources cited are Julia 1.12.7's own: `base/` and `juliac/` under `share/julia`, and the C runtime at
the tag `v1.12.7`.

## The session has already run every `__init__`

- When a module's outermost definition finishes outside output generation, Julia runs the `__init__`
  of that module and of its submodules, children first (`src/toplevel.c:207-209`, `:215-240`).
- A package restored in a session runs its `__init__` at load (`base/loading.jl:1432` loops the image's
  `inits`; `:1443` `run_module_init` calls `jl_init_restored_module`, `src/module.c:2085`).
- So the heap of the session WasmTarget compiles in has run every loaded module's `__init__` exactly
  once.

## juliac runs them at startup only because its build deferred them

- While output is being generated, a finished definition runs nothing (`src/toplevel.c:215`), and a
  restored package's `__init__` goes on the init list instead of running (`src/module.c:2087`,
  `jl_add_to_module_init_list`).
- At output, each listed module with an `__init__` stays on the list. Under `--trim`, each is also a
  trim entrypoint (`src/precompile.c:111-141`), verified by `typeinf_ext_toplevel`
  (`Compiler/src/typeinfer.jl:1534`). The list is saved in the image (`src/staticdata.c:276`).
- At startup, `src/init.c:618-628` runs the list.
- juliac makes `Base.__init__` verify by stubbing its host setup (`juliac/juliac-trim-base.jl:11-20`,
  `:147`), and rewrites stdlib initializers that do not trim (`juliac/juliac-trim-stdlib.jl`).
- So juliac's image starts from the heap before any `__init__`, and its startup brings it to the heap
  after every `__init__`. That is the heap the session already holds.

## The ruling

1. **WasmTarget compiles no module `__init__`.** A program starts from the session's heap, which is
   juliac's heap after startup. Compiling an `__init__` into the start function would run it a second
   time. The measured case is `test/src/globals.jl`'s `InitTwice`: its `__init__` adds one to a `Ref`.
   The session holds 1, native `read_seen(1)` is 2, and a second run would make it 3.
2. **A binding starts at its session value.** `nir_binding_value` (`src/julia/nir.jl`) is the one source:
   - globals.dart's constant initializer reads it;
   - the lazy initializer function reads it, through `StaticFieldInitializerCodeGenerator`;
   - Constants instantiates the value, `===`-canonical, so an object keeps its identity.
3. **Core and Base are the runtime's.** A module whose `parentmodule` chain reaches `Core` or `Base` is
   the runtime's (`runtime_module`). Its `__init__` set up the host process (`base/Base.jl:368`):
   - stdio, through `reinit_stdio`;
   - the depot and load paths and the active project;
   - the logger;
   - in its submodules, `Sys` (`base/sysinfo.jl:150`), `GMP` (`base/gmp.jl:108`) and `MPFR`
     (`base/mpfr.jl:46`).

   dart2wasm's counterpart is the embedder's setup of the JS runtime. A binding of such a module that
   is not const, or holds a mutable value, is host state: `stdout`, `DEPOT_PATH`, `Sys.CPU_THREADS`, the
   logger. Each is a located rejection naming "Base.__init__ (the runtime's)". A const value free of
   mutation, such as `Sys.WORD_SIZE`, is Julia's own value and is read as any other.

## Known deviation from juliac

A value an `__init__` derived from the host is fixed at compile time, where juliac computes it at
startup:
- a `dlopen` handle;
- a time;
- the seed `Random.__init__` gives the default RNG, so an unseeded `rand()` repeats from one run to the
  next.

A pointer or handle is only usable through a foreigncall, which is a host import (dev/MARCH.md 1.F).
`nir_binding_value` carries a `@quarantine` naming this deviation.
