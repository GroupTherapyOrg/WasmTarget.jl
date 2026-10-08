# ============================================================================
# Code Generation
# ============================================================================


"""
    _get_local_type(ctx, local_idx) -> Union{WasmValType, Nothing}

Get the Wasm type of a local variable by its index. Parameters come first,
then additional locals from ctx.locals.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1018 InstructionsBuilder.local_get)
"""
function _get_local_type(ctx::AbstractCompilationContext, local_idx::Int)::Union{WasmValType, Nothing}
    if local_idx < ctx.n_params
        # It's a parameter — get type from arg_types (skip WasmGlobal args)
        param_count = 0
        for (i, T) in enumerate(ctx.arg_types)
            if i in ctx.global_args
                continue
            end
            if param_count == local_idx
                return get_concrete_wasm_type(T, ctx.mod, ctx.type_registry)
            end
            param_count += 1
        end
        return nothing
    else
        # It's an additional local
        local_offset = local_idx - ctx.n_params
        if local_offset >= 0 && local_offset < length(ctx.locals)
            return ctx.locals[local_offset + 1]  # 1-indexed
        end
        return nothing
    end
end

"""
Generate Wasm bytecode from Julia CodeInfo.
Uses a block-based translation for control flow.

parity(code_generator.dart:38 CodeGenerator.generate)
"""
function generate_body(ctx::AbstractCompilationContext)::Tuple{Vector{UInt8},Vector{SourceMapping}}
    # Analyze control flow to find basic block structure
    blocks = analyze_blocks(ctx.nir)

    # The finalized typed instruction stream is authoritative. In particular,
    # post-return code is already stack-polymorphic in the builder; no serialized
    # opcode may be inspected or rewritten after this point.
    return generate_structured(ctx, blocks)
end






"""
Represents a basic block in the IR.
parity(quarantine: Julia's IR is a CFG of gotos; WT recovers its blocks and structure, where dart's kernel tree carries its structure (dev/formal/Stackifier.tla).)
"""
struct BasicBlock
    start_idx::Int
    end_idx::Int
    terminator::Union{NirGotoIfNot, NirGoto, NirReturn, Nothing}   # nothing: falls through
end

"""
Represents a try/catch region in the IR.

parity(quarantine: Julia's typed IR marks a try as a flat Core.EnterNode with a catch_dest and a later :leave, where Kernel has a structured TryCatch node; the region's three statement indices are what the stackifier nests into try_table)
"""
struct TryRegion
    enter_idx::Int      # SSA index of Core.EnterNode
    catch_dest::Int     # SSA index where catch block starts
    leave_idx::Int      # SSA index of :leave expression (end of try body)
end

"""
Find try/catch regions by scanning for try-region entries (`Core.EnterNode`).
Returns a list of TryRegion structs.

parity(quarantine: Julia's typed IR marks a try as a flat Core.EnterNode and a later :leave
naming it, where Kernel has a structured TryCatch node; this scan pairs them into the
TryRegion the stackifier nests into try_table.)
"""
function find_try_regions(nir::Vector{NirStmt})::Vector{TryRegion}
    regions = TryRegion[]

    for (i, rec) in enumerate(nir)
        if rec.node isa NirEnter
            catch_dest = rec.node.catch_target
            # Find the corresponding :leave that references this EnterNode
            leave_idx = something(findfirst(nir) do s
                s.node isa NirLeave && any(a -> a isa NirSSA && a.id == i, s.node.enters)
            end, 0)

            if leave_idx > 0
                push!(regions, TryRegion(i, catch_dest, leave_idx))
            elseif catch_dest > i
                # An always-throwing try body has NO :leave (Julia elides
                # it when the body can't exit normally — e.g. `try div(0,0) catch`).
                # Dropping the region here meant no try_table was emitted at all, so
                # the throw escaped uncaught. Synthesize leave_idx = catch_dest: the
                # try body becomes enter+1 .. catch_dest-1 and every consumer's
                # normal-exit range (leave_idx+1 .. catch_dest-1) is empty, which is
                # exactly right — there is no normal exit.
                push!(regions, TryRegion(i, catch_dest, catch_dest))
            end
        end
    end

    return regions
end

"""
Check if the IR contains try/catch regions.

parity(quarantine: Julia's typed IR marks a try as a flat Core.EnterNode statement, where Kernel has a structured TryCatch node)
"""
has_try_catch(nir::Vector{NirStmt})::Bool = any(rec -> rec.node isa NirEnter, nir)

"""
    stmt_is_proven_unreachable(nir, idx) -> Bool

Return `true` only when the ordinary Julia CFG proves that `idx` cannot be reached
from entry.  This is the sole condition under which an unsupported lowering may be
kept as a diagnosed validating trap instead of rejecting compilation.  Uncertainty
(including exception-bearing CFGs) is reachable for soundness purposes.

parity(quarantine: Julia's typed IR is a goto CFG that can keep blocks no edge reaches, and a
trap is sound only in such a block; dart's TFA removes unreachable members before codegen
(code_generator.dart:5084 UnreachableCodeGenerator), so Kernel code never needs a statement
reachability proof.)
formal(dev/formal/ProvenDead.tla): a statement proven dead has no control-flow path from entry
"""
function stmt_is_proven_unreachable(nir::Vector{NirStmt}, idx::Int)::Bool
    1 <= idx <= length(nir) || return false
    has_try_catch(nir) && return false
    blocks = analyze_blocks(nir)
    isempty(blocks) && return false
    bidx = findfirst(b -> b.start_idx <= idx <= b.end_idx, blocks)
    bidx === nothing && return false
    start2id = Dict{Int,Int}(blocks[i].start_idx => i for i in eachindex(blocks))
    reachable = falses(length(blocks))
    reachable[1] = true
    work = Int[1]
    while !isempty(work)
        bi = pop!(work)
        term = blocks[bi].terminator
        successors = Int[]
        if term isa NirGoto
            haskey(start2id, term.target) && push!(successors, start2id[term.target])
        elseif term isa NirGotoIfNot
            haskey(start2id, term.target) && push!(successors, start2id[term.target])
            bi < length(blocks) && push!(successors, bi + 1)
        elseif !(term isa NirReturn)
            bi < length(blocks) && push!(successors, bi + 1)
        end
        for si in successors
            reachable[si] || (reachable[si] = true; push!(work, si))
        end
    end
    return !reachable[bidx]
end

"""
Analyze the IR to find basic block boundaries.
A new block starts after each terminator AND at each jump target.
parity(quarantine: Julia's IR is a CFG of gotos; WT recovers its blocks and structure, where dart's kernel tree carries its structure (dev/formal/Stackifier.tla).)
"""
function analyze_blocks(nir::Vector{NirStmt})::Vector{BasicBlock}
    # First, collect all jump targets
    jump_targets = Set{Int}()
    for rec in nir
        if rec.node isa NirGoto || rec.node isa NirGotoIfNot
            push!(jump_targets, rec.node.target)
        end
    end

    blocks = BasicBlock[]
    block_start = 1

    for i in 1:length(nir)
        node = nir[i].node

        # Check if NEXT statement is a jump target (start new block after this one)
        next_is_jump_target = (i + 1) in jump_targets

        if node isa NirGotoIfNot || node isa NirGoto || node isa NirReturn
            push!(blocks, BasicBlock(block_start, i, node))
            block_start = i + 1
        elseif next_is_jump_target && i >= block_start
            # Current statement is NOT a terminator but next statement IS a jump target
            # Close current block with no terminator (fallthrough)
            push!(blocks, BasicBlock(block_start, i, nothing))
            block_start = i + 1
        end
    end

    # Handle trailing code without explicit terminator
    if block_start <= length(nir)
        push!(blocks, BasicBlock(block_start, length(nir), nothing))
    end

    return blocks
end


"""
    ensure_exception_tag!(mod)

The module's one exception tag, index 0 (idempotent), whose payload is the exception and the
stack trace of its throw, as dart's exception tag carries (exception, stackTrace), and a third
value, the entry of Julia's exception stack its throw pushed (exc_cell_type!), so the entry
travels with the unwind and the catch that lands it makes it the top by identity
(stackified.jl). A try region's `try_table` catches it with `catch 0`, landing the payload in
its handler. A host reads the first two values (getArg(tag, 0) and 1).
parity(tags.dart:37 ExceptionTags._defineDartExceptionTag)
parity(quarantine: Julia's stack entries have identity and outlive an unwind (one object thrown twice is two entries); dart's tag carries (exception, stackTrace) alone, tags.dart:37.)
"""
function ensure_exception_tag!(mod::WasmModule)::Union{Nothing, UInt32}
    # THE TYPED TAG — dart's _defineDartExceptionTag carries
    # (exception, stackTrace) as the tag payload (tags.dart:37);
    # the value travels WITH the unwind, not via a pre-set global (re-entrancy).
    # Payload: (anyref exn, externref stackTrace — the JS stack its throw captured,
    # emit_throw_value!, which a rethrow throws again; ref null $cell — its entry).
    if isempty(mod.tags)
        tag_ft = FuncType(WasmValType[AnyRef, ExternRef, ConcreteRef(exc_cell_type!(mod), true)], WasmValType[])
        add_tag!(mod, add_type!(mod, tag_ft))
    end
end

"""
    emit_throw_value!(b, mod) -> b

Throw the Julia exception on the stack: capture the stack trace at the throw (the imported
`wasmtarget.stack_trace` answers `new Error()`), push it and the exception as a new entry of
Julia's exception stack (task.c throw_internal, jl_push_excstack), and throw the tag with the
entry's exception and stack, and the entry. The one throw every raise ends in, as every dart
throw captures `StackTrace.current` into the tag's stack slot (`errorThrowWithCurrentStackTrace`).
formal(dev/formal/ExceptionStack.tla): a throw pushes, a rethrow does not, an enter's saved top
is its depth, and every read and raised value is Julia's.
parity(pkg/dart2wasm/lib/code_generator.dart:2955 CodeGenerator.visitThrow)
"""
function emit_throw_value!(b::InstrBuilder, mod::WasmModule)::InstrBuilder
    ensure_exception_tag!(mod)
    local cell = exc_cell_type!(mod)
    local top = ensure_exception_top_global!(mod)
    call!(b, something(_stack_trace_func_idx(mod)), WasmValType[], WasmValType[ExternRef])
    struct_new!(b, cell)
    global_set!(b, top)
    _emit_throw_top!(b, mod)
    return b
end

# throw the tag with the top entry's exception and stack and the entry, pushing nothing
# (jl_rethrow's throw_internal(ct, NULL))
# parity(pkg/dart2wasm/lib/code_generator.dart:2966 CodeGenerator.visitRethrow)
function _emit_throw_top!(b::InstrBuilder, mod::WasmModule)::InstrBuilder
    local cell = exc_cell_type!(mod)
    local top = ensure_exception_top_global!(mod)
    global_get!(b, top, ConcreteRef(cell, true))
    struct_get!(b, cell, 0, AnyRef)
    global_get!(b, top, ConcreteRef(cell, true))
    struct_get!(b, cell, 1, ExternRef)
    global_get!(b, top, ConcreteRef(cell, true))
    throw_!(b, 0)
    return b
end

"""
    emit_rethrow!(b, mod, registry; other=nothing) -> b

Julia's `rethrow()` (task.c jl_rethrow): throw the top entry of the exception stack again,
with the stack its throw captured, pushing nothing. With `other`, the local holding `e`,
Julia's `rethrow(e)` (jl_rethrow_other): `e` overwrites the top entry's exception first. At
depth 0 either throws Julia's ErrorException instead ("rethrow() not allowed outside a catch
block", "rethrow(exc) not allowed outside a catch block"), which pushes as every throw does.
parity(pkg/dart2wasm/lib/code_generator.dart:2966 CodeGenerator.visitRethrow)
"""
function emit_rethrow!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry;
                       other::Union{Nothing,Integer}=nothing)::InstrBuilder
    local cell = exc_cell_type!(mod)
    local top = ensure_exception_top_global!(mod)
    global_get!(b, top, ConcreteRef(cell, true))
    ref_is_null!(b)
    if_!(b)
    local info = register_struct_type!(mod, registry, ErrorException)
    info === nothing && error("ErrorException layout is unavailable")
    emit_struct_prefix!(b, registry, ErrorException, info)
    local msg = other === nothing ? "rethrow() not allowed outside a catch block" :
                                    "rethrow(exc) not allowed outside a catch block"
    local g = get_string_constant_global!(mod, registry, msg; eager=true)
    global_get!(b, g, ConcreteRef(get_string_struct_type!(mod, registry), false))
    struct_new!(b, info.wasm_type_idx)
    emit_throw_value!(b, mod)
    end_block!(b)
    if other !== nothing
        global_get!(b, top, ConcreteRef(cell, true))
        local_get!(b, UInt32(other))
        struct_set!(b, cell, 0, AnyRef)
    end
    return _emit_throw_top!(b, mod)
end

"""
    emit_current_exception!(b, mod) -> b

Julia's `the_exception` (jl_current_exception): the top entry's exception, `nothing` (the
null reference) when the exception stack is empty.
parity(quarantine: Julia's per-task exception stack, read by the_exception; dart binds its catch's exception to a local, code_generator.dart:958 visitTryCatch.)
"""
function emit_current_exception!(b::InstrBuilder, mod::WasmModule)::InstrBuilder
    local cell = exc_cell_type!(mod)
    local top = ensure_exception_top_global!(mod)
    global_get!(b, top, ConcreteRef(cell, true))
    ref_is_null!(b)
    if_!(b; results=WasmValType[AnyRef])
    ref_null!(b, AnyRef)
    else_!(b)
    global_get!(b, top, ConcreteRef(cell, true))
    struct_get!(b, cell, 0, AnyRef)
    end_block!(b)
    return b
end

"""
The JavaScript each host import WT's code generator creates is answered with, by
(module, field): the module's runtime, as dart2wasm generates the JS methods its module imports
(RuntimeFinalizer.generate). A traced compile's `wasmtarget.trace_*` imports are answered by
its harness (test/trace_localize.jl), not here. L150 keeps this table and the imports equal.
parity(pkg/dart2wasm/lib/js/runtime_generator.dart:128 RuntimeFinalizer.generate)
"""
const HOST_RUNTIME = [
    ("wasmtarget", "stack_trace", "() => new Error()"),
    ("env", "perf_now", "() => performance.now()"),
    ("env", "random_i64", "() => { const a = new BigInt64Array(1); crypto.getRandomValues(a); return a[0]; }"),
]

"""
    host_runtime_js() -> String

The import object a host instantiates a WasmTarget module with, as a JavaScript expression:
every import WT's code generator creates, answered as HOST_RUNTIME says. A host adds its own
imports beside it (a framework's, or a test's deterministic clock) and may answer one of these
differently.
parity(pkg/dart2wasm/lib/js/runtime_generator.dart:128 RuntimeFinalizer.generate)
"""
function host_runtime_js()::String
    local mods = unique(first.(HOST_RUNTIME))
    return "{ " * join(("$(m): { " * join(("$(f): $(js)" for (mm, f, js) in HOST_RUNTIME if mm == m), ", ") * " }"
                        for m in mods), ", ") * " }"
end

"""
    ensure_provenance_imports!(mod)

What every module adds when it is created, before any definition: the import
`wasmtarget.stack_trace: () -> externref`, which the host answers with `new Error()` (the JS
stack at the call: dart2wasm's JavaScriptStack.current; host_runtime_js), and the export of
the exception tag as `wasmtarget.exception`, so a host that catches an escaped Julia exception
can read the stack of its throw from the tag's payload. Recording a source map changes none of
this: it only maps the code.
parity(sdk/lib/_internal/wasm/js_common/js_helper.dart:857 JavaScriptStack.current)
"""
function ensure_provenance_imports!(mod::WasmModule)::Nothing
    _stack_trace_func_idx(mod) === nothing &&
        add_import!(mod, "wasmtarget", "stack_trace", WasmValType[], WasmValType[ExternRef])
    ensure_exception_tag!(mod)
    any(e -> e.name == "wasmtarget.exception", mod.exports) ||
        add_export!(mod, "wasmtarget.exception", 4, 0)
    return nothing
end

# The Julia types whose statements a traced compile reports, and the wasm local each lives in:
# exactly Julia's bits, so a traced value compares bit for bit with the native one.
# parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
const TRACED_STATEMENT_TYPES = Dict{Type,WasmValType}(Int64 => I64, UInt64 => I64, Int32 => I32,
                                                      Bool => I32, Float32 => F32, Float64 => F64)

"""
    ensure_trace_imports!(mod)

The imports a traced compile's probes call: `wasmtarget.trace_enter(function::i32)` on entry
to a traced function, and one per traced wasm type,
`wasmtarget.trace_i32/i64/f32/f64(function::i32, statement::i32, value)`. Added when the
module is created, before any definition.
parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
"""
function ensure_trace_imports!(mod::WasmModule)::Nothing
    _import_func_idx(mod, "wasmtarget", "trace_enter") === nothing &&
        add_import!(mod, "wasmtarget", "trace_enter", WasmValType[I32], WasmValType[])
    for (name, T) in (("trace_i32", I32), ("trace_i64", I64), ("trace_f32", F32), ("trace_f64", F64))
        _import_func_idx(mod, "wasmtarget", name) === nothing &&
            add_import!(mod, "wasmtarget", name, WasmValType[I32, I32, T], WasmValType[])
    end
    return nothing
end

# a traced function's trace id, or nothing
# parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
_trace_id(ctx::AbstractCompilationContext)::Union{Nothing,Int} =
    ctx.translator.trace === nothing ? nothing : get(ctx.translator.trace.ids, ctx.func_idx, nothing)

"""
    emit_trace_enter!(b, ctx) -> b

At the start of a traced function's body, report entering it: `wasmtarget.trace_enter(id)`, so
the host sees every function's probes in the order the calls ran.
parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
"""
function emit_trace_enter!(b::InstrBuilder, ctx::AbstractCompilationContext)::InstrBuilder
    local id = _trace_id(ctx)
    id === nothing && return b
    i32_const!(b, id)
    call!(b, something(_import_func_idx(ctx.mod, "wasmtarget", "trace_enter")), WasmValType[I32], WasmValType[])
    return b
end

"""
    emit_statement_trace!(b, ctx, idx, local_idx, local_type) -> b

In a traced function of a traced compile, report statement `idx`'s value (just stored in
`local_idx`) to the host: `wasmtarget.trace_<type>(id, idx, value)`, for a statement of a
traced type. Nothing otherwise.
parity(quarantine: a traced compile reports each statement's value to the host so a wrong value is located at its first divergent statement; dart has no statement-value trace.)
"""
function emit_statement_trace!(b::InstrBuilder, ctx::AbstractCompilationContext, idx::Int,
                               local_idx::Integer, local_type)::InstrBuilder
    local id = _trace_id(ctx)
    id === nothing && return b
    local T = get(ctx.ssa_types, idx, Any)
    get(TRACED_STATEMENT_TYPES, T, nothing) === local_type || return b
    local name = local_type === I64 ? "trace_i64" : local_type === I32 ? "trace_i32" :
                 local_type === F32 ? "trace_f32" : "trace_f64"
    i32_const!(b, id)
    i32_const!(b, idx)
    local_get!(b, local_idx)
    call!(b, something(_import_func_idx(ctx.mod, "wasmtarget", name)), WasmValType[I32, I32, local_type], WasmValType[])
    push!(ctx.translator.trace.probed[id], idx)
    return b
end

# the function index of an imported function, or nothing
# parity(pkg/wasm_builder/lib/src/builder/functions.dart:43 FunctionsBuilder.import)
function _import_func_idx(mod::WasmModule, module_name::String, field_name::String)::Union{Nothing,UInt32}
    local n = 0
    for imp in mod.imports
        imp.kind == 0x00 || continue
        (imp.module_name == module_name && imp.field_name == field_name) && return UInt32(n)
        n += 1
    end
    return nothing
end

# the function index of the imported `wasmtarget.stack_trace`, or nothing
# parity(sdk/lib/_internal/wasm/js_common/js_helper.dart:857 JavaScriptStack.current)
_stack_trace_func_idx(mod::WasmModule)::Union{Nothing,UInt32} = _import_func_idx(mod, "wasmtarget", "stack_trace")

"""
    exc_cell_type!(mod) -> type_idx

One entry of Julia's exception stack: its exception, which `rethrow(e)` overwrites, and the
stack trace its throw captured. Julia's entry also links the one below it; nothing in WT
reads below the top except through the top an enter saved, so an entry holds no link.
parity(quarantine: Julia's per-task exception stack (task.c jl_push_excstack) is dynamic state that rethrow() and callees read; dart binds its exception and stack to its catch's locals, code_generator.dart:958 visitTryCatch.)
"""
exc_cell_type!(mod::WasmModule)::UInt32 =
    add_type!(mod, StructType([FieldType(AnyRef, true), FieldType(ExternRef, false)]))

"""
    ensure_exception_top_global!(mod) -> global_idx

The top of Julia's exception stack, `\$exc_top`, a mutable nullable reference to its entry,
null while the stack is empty; defined once and found by its name (global_named).
parity(quarantine: Julia's per-task exception stack, whose top a throw, a pop_exception and rethrow(e) change; dart has none.)
"""
function ensure_exception_top_global!(mod::WasmModule)::UInt32
    local g = global_named(mod, "\$exc_top")
    g === nothing || return g
    return add_global!(mod, ConcreteRef(exc_cell_type!(mod), true), true, nothing; name="\$exc_top")
end

"""
    emit_export_entry!(mod, inner_idx, name) -> func_idx

The function an export calls in place of `inner_idx`, as the host is the catching frame whose
JL_TRY records the depth of Julia's exception stack and whose JL_CATCH restores it
(jl_restore_excstack) on every escape. A call made with no host-declared import open is
top-level and starts with an empty stack (Julia's host call does, whatever the previous call
did); a re-entrant one, from inside a host-declared import, starts with its caller's. The entry
saves the top and the count of open host-declared imports (host_imports_open_global!), calls
the inner inside a result-less `try_table (catch_all_ref)`, and when anything catchable escapes,
a Julia exception or a foreign one (a JS exception from an import, the engine's RangeError),
restores both and rethrows it with `throw_ref`, its payload unchanged. Between a host-import
call site and this entry every frame is Julia's, which catches only the tag, so this is the one
observer of a foreign unwind. A trap is not catchable and restores nothing: the host contract
says an instance that trapped is discarded (dev/MARCH.md 13.17, H6 and H7). The inner keeps the
export's name; this one is "<name> (export)", as dart names an import "<name> (import)"
(functions.dart:141).
formal(dev/formal/ExceptionStack.tla): every escape leaves the stack as Julia's host leaves it, except H6 and H7 (traps).
parity(quarantine: Julia's per-task exception stack outlives a call; the host is the catching frame that restores its depth on every escape, jl_restore_excstack; dart's catch state is lexical, code_generator.dart:2966 visitRethrow. Its catch_all_ref is L101's one allowed site: catch_all is the only wasm construct that observes a foreign unwind.)
"""
function emit_export_entry!(mod::WasmModule, inner_idx::Integer, name::String)::UInt32
    local ft = mod.types[Int(mod.functions[Int(inner_idx) - num_imported_funcs(mod) + 1].type_idx) + 1]::FuncType
    local top = ensure_exception_top_global!(mod)
    local cell = ConcreteRef(exc_cell_type!(mod), true)
    local count = host_imports_open_global!(mod)
    local b = InstrBuilder(copy(ft.params), copy(ft.results); func_name="emit_export_entry!", mod=mod)
    local saved = builder_add_local!(b, cell)
    # a top-level call (no host-declared import open; every call, in a module with none) starts
    # with an empty stack
    count === nothing || (global_get!(b, count, I32); num!(b, Opcode.I32_EQZ); if_!(b))
    ref_null!(b, cell.type_idx, cell); global_set!(b, top)
    count === nothing || end_block!(b)
    global_get!(b, top, cell); local_set!(b, saved)
    local saved_count = count === nothing ? nothing : builder_add_local!(b, I32)
    count === nothing || (global_get!(b, count, I32); local_set!(b, saved_count))
    # the try_table has no results: the call's results go to locals, as every try_table WT emits
    # (V8 12.4, Node 22, traps on entering a try_table whose result is a reference)
    local result_locals = Int[builder_add_local!(b, r) for r in ft.results]
    local escaped = block!(b; results=WasmValType[ExnRef])
    try_table!(b, [catch_all_ref_clause(escaped)])
    for i in 0:length(ft.params) - 1; local_get!(b, i); end
    call!(b, inner_idx, ft.params, ft.results)
    for l in reverse(result_locals); local_set!(b, l); end
    end_block!(b)
    for l in result_locals; local_get!(b, l); end
    return_!(b)
    end_block!(b)
    local_get!(b, saved); global_set!(b, top)
    count === nothing || (local_get!(b, saved_count); global_set!(b, count))
    throw_ref!(b)
    finish_function!(b)
    return add_function!(mod, ft.params, ft.results, b.locals[length(ft.params) + 1:end],
                         builder_code(b); name=name * " (export)")
end

"""
    host_imports_open_global!(mod) -> Union{Nothing, UInt32}

`\$host_imports_open`, the count of open calls of host-declared imports (emit_direct_call!),
defined once and found by its name; `nothing` in a module with no host-declared import, where
every export call is top-level. WT's own runtime imports (HOST_RUNTIME, a traced compile's
`wasmtarget.trace_*`) never call an export back and count nothing.
parity(quarantine: Julia's host call starts with an empty exception stack and a re-entrant one with its caller's; a call is re-entrant iff a host import that may call back is open, which wasm cannot observe but by counting; dart has no exception stack.)
"""
function host_imports_open_global!(mod::WasmModule)::Union{Nothing,UInt32}
    local g = global_named(mod, "\$host_imports_open")
    g === nothing || return g
    any(imp -> _is_host_declared_import(imp), mod.imports) || return nothing
    return add_global!(mod, I32, true, 0; name="\$host_imports_open")
end

# an imported function the host declared, not one of WT's own runtime imports
# parity(quarantine: Julia's host call starts with an empty exception stack and a re-entrant one with its caller's; only a host-declared import can call an export back.)
_is_host_declared_import(imp)::Bool =
    imp.kind == 0x00 && imp.module_name != "wasmtarget" &&
    !any(((m, f, _),) -> m == imp.module_name && f == imp.field_name, HOST_RUNTIME)

"""
    emit_direct_call!(b, mod, func_idx) -> b

A direct call of the function a registry or a host binding names, its arguments on the stack.
A call of a host-declared import counts itself open in `\$host_imports_open` while it runs, so
an export the host calls from inside it is re-entrant (emit_export_entry!).
formal(dev/formal/ExceptionStack.tla): ImportCall and ImportReturn.
parity(quarantine: Julia's host call starts with an empty exception stack and a re-entrant one with its caller's; a call is re-entrant iff a host import that may call back is open, which wasm cannot observe but by counting; dart's call, instructions.dart:947, counts nothing.)
"""
function emit_direct_call!(b::InstrBuilder, mod::WasmModule, func_idx::Integer)::InstrBuilder
    local imports = filter(imp -> imp.kind == 0x00, mod.imports)
    local count = Int(func_idx) < length(imports) && _is_host_declared_import(imports[Int(func_idx) + 1]) ?
                  host_imports_open_global!(mod) : nothing
    count === nothing || (global_get!(b, count, I32); i32_const!(b, 1); num!(b, Opcode.I32_ADD); global_set!(b, count))
    call!(b, func_idx, WasmValType[], WasmValType[])
    count === nothing || (global_get!(b, count, I32); i32_const!(b, 1); num!(b, Opcode.I32_SUB); global_set!(b, count))
    return b
end

"""
    exc_saved_local!(ctx, enter_idx) -> local

The local where try region `enter_idx` keeps the top of the exception stack when it is
entered, its depth: its pop_exception restores it, as Julia's enter records
jl_excstack_state and pop_exception calls jl_restore_excstack. With `count`, the local where
it keeps `\$host_imports_open`, which its catch landing restores (keyed by `-enter_idx`).
parity(quarantine: Julia's exception stack is task state that a region's enter and pop_exception save and restore; dart binds each catch's exception to its own locals (code_generator.dart:958 visitTryCatch).)
"""
function exc_saved_local!(ctx::AbstractCompilationContext, enter_idx::Int; count::Bool=false)::Int
    return get!(ctx.exc_saved_locals, count ? -enter_idx : enter_idx) do
        allocate_local!(ctx, count ? I32 : ConcreteRef(exc_cell_type!(ctx.mod), true))
    end
end


