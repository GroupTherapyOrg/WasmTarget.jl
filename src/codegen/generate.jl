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

    # the function's entry, before any instruction, maps to its definition, as dart sets the
    # member's offset before it generates the body (code_generator.dart:3625)
    b = _ctx_builder(ctx, "generate_structured")
    map_to_definition!(b, ctx)

    # The finalized typed instruction stream is authoritative. In particular,
    # post-return code is already stack-polymorphic in the builder; no serialized
    # opcode may be inspected or rewritten after this point.
    return generate_structured(b, ctx, blocks)
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

parity(quarantine: Julia's typed IR marks a try as a flat Core.EnterNode with a catch_dest and a later :leave, where Kernel has a structured TryCatch node; the region's three statement indices are what the stackifier nests into a try)
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
TryRegion the stackifier nests into a try.)
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
                # Dropping the region here meant no try was emitted at all, so
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
(stackified.jl). A try region's legacy `try` catches it with `catch 0`, its payload the try's
outputs, delivered at its end where the handler begins. A host reads the first two values
(getArg(tag, 0) and 1).
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
    call!(b, something(_stack_trace_func_idx(mod)))
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
    global_get!(b, top)
    struct_get!(b, cell, 0)
    global_get!(b, top)
    struct_get!(b, cell, 1)
    global_get!(b, top)
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
    global_get!(b, top)
    ref_is_null!(b)
    if_!(b)
    local info = register_struct_type!(mod, registry, ErrorException)
    info === nothing && error("ErrorException layout is unavailable")
    emit_struct_prefix!(b, registry, ErrorException, info)
    local msg = other === nothing ? "rethrow() not allowed outside a catch block" :
                                    "rethrow(exc) not allowed outside a catch block"
    local g = get_string_constant_global!(mod, registry, msg; eager=true)
    global_get!(b, g)
    struct_new!(b, info.wasm_type_idx)
    emit_throw_value!(b, mod)
    end_block!(b)
    if other !== nothing
        global_get!(b, top)
        local_get!(b, UInt32(other))
        struct_set!(b, cell, 0)
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
    global_get!(b, top)
    ref_is_null!(b)
    if_!(b; results=WasmValType[AnyRef])
    ref_null!(b, AnyRef)
    else_!(b)
    global_get!(b, top)
    struct_get!(b, cell, 0)
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
differently. A host discards an instance that trapped, as policy (host_glue_js).
parity(pkg/dart2wasm/lib/js/runtime_generator.dart:128 RuntimeFinalizer.generate)
"""
function host_runtime_js()::String
    local mods = unique(first.(HOST_RUNTIME))
    return "{ " * join(("$(m): { " * join(("$(f): $(js)" for (mm, f, js) in HOST_RUNTIME if mm == m), ", ") * " }"
                        for m in mods), ", ") * " }"
end

"""
    host_glue_js() -> String

The glue a host instantiates a WasmTarget module through, as a JavaScript expression: a function
`(importObject) => importObject'`. It creates the count of open calls of host-declared imports,
`open`, a mutable i32 `WebAssembly.Global`, and hands it to the module as
`wasmtarget.host_imports_open` (ensure_host_imports_open!); it wraps every function the import
object holds that is a host-declared import (_is_host_declared_import: not of module
`wasmtarget`, not answered by HOST_RUNTIME, whose list it reads) in
`(...a) => { open.value++; try { return f(...a); } finally { open.value--; } }`. The finally runs
on every exit of the import's frame, also when stack exhaustion or a trap below it, which no wasm
catch observes, unwinds it, so the count is exact at every point, and no wasm code writes it. An
export the host calls while the count is not 0 is re-entrant (emit_export_entry!). The count is
the instance's: the glued object hands each wrapped import and the count out once, to the
instantiation that reads them, and a second read throws, so one glued object serves one
instance and the host never calls a glued import itself (it calls its own function), either of
which would count a call no call of this instance made (ExceptionStack.tla HostCallsGlued). A
module with a host-declared import instantiated without the glue is refused: its count is a
missing import. A host discards an instance that trapped, as policy: a trap is not a Julia error
(where WT traps, Julia often raises an error a `catch` catches), so what an instance answers
after a trap is outside the contract, though its exception stack stays Julia's
(ExceptionStack.tla HostCatchesTrap, PropagatesTrap).
formal(dev/formal/ExceptionStack.tla): GlueFinally, the count lowered on every exit of an import; HostCallsGlued = FALSE, each glued import read once.
parity(quarantine: Julia's host is the catching frame of every call, julia.h:2548/:2555, and the only frame that observes stack exhaustion and traps, which V8 lets no wasm catch observe, legacy or exnref (measured on Node 22.23.3 and 26.11.0); dart generates the JS for each import, js/runtime_generator.dart:60 generateJsMethods, and wraps none in a finally)
"""
function host_glue_js()::String
    local runtime = join(("$(repr(m)): [" * join((repr(f) for (mm, f, _) in HOST_RUNTIME if mm == m), ", ") * "]"
                          for m in unique(first.(HOST_RUNTIME))), ", ")
    return "((importObject) => { " *
           "const open = new WebAssembly.Global({ value: 'i32', mutable: true }, 0); " *
           "const runtime = { $(runtime) }; const glued = {}; " *
           "const once = (o, m, f, v) => { let read = false; Object.defineProperty(o, f, { enumerable: true, get: () => { " *
           "if (read) throw new Error('the glued import ' + m + '.' + f + ' was read twice: a glued import object serves " *
           "one instance, and the host calls its own function, never the glued one (WasmTarget.host_glue_js)'); " *
           "read = true; return v; } }); }; " *
           "for (const [m, fs] of Object.entries(importObject)) { glued[m] = Object.assign({}, fs); " *
           "if (m === 'wasmtarget') continue; " *
           "for (const [f, fn] of Object.entries(fs)) { " *
           "if (typeof fn !== 'function' || (runtime[m] || []).includes(f)) continue; " *
           "once(glued[m], m, f, (...a) => { open.value++; try { return fn(...a); } finally { open.value--; } }); } } " *
           "glued.wasmtarget = Object.assign({}, glued.wasmtarget); " *
           "once(glued.wasmtarget, 'wasmtarget', 'host_imports_open', open); " *
           "return glued; })"
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

"""
    ensure_class_id_reader!(mod, registry, translator)

The provenance export beside the exception tag: `wasmtarget.class_id: (anyref) -> i32`, the
classId of an escaped exception, which a host that catches an escape reads from the tag's payload
(`getArg(tag, 0)`, host_escape_js) and names as dart prints a type in a minified build,
`minified:Class<id>` (type.dart:344), resolved through the source map's class names
(add_minified_class_names). Its body is emit_class_id!'s rule over `Any`, the one rule every class
read uses: null is Nothing, a bare array whose wasm type one class has answers that class, and a
value without a header (a type object, a bare array whose wasm type classes share) traps at the
cast, never a guessed class. Defined at the end of compile_module, over the final numbering, the
last of the module's functions; in a module compiled into again (existing_module) its body is
replaced in its slot, the name passed on (L157).
parity(quarantine: WT's export boundary is the host's glue (L156: an export entry holds no try and no local), so the catch dart's `\$invokeMain` makes inside wasm, invoke_main_patch.dart:43-52, is made by the host, which reads the escaped value's class through this one exported reader, code_generator.dart:6076 loadClassId)
"""
function ensure_class_id_reader!(mod::WasmModule, registry::TypeRegistry, translator::Translator)::Nothing
    local ctx = CompilationContext(NirBody(NirStmt[], Type[Any], nothing), (Any,), Int32, mod, registry;
                                   translator=translator)
    local b = InstrBuilder(WasmValType[AnyRef], WasmValType[I32]; func_name="ensure_class_id_reader!", mod=mod)
    _seed_builder_locals!(b, ctx)   # the locals emit_class_id! allocates on ctx
    local_get!(b, 0)
    emit_class_id!(b, ctx, Any)
    finish_function!(b)
    local name = generated_function_name(:class_id_reader)
    local k = findfirst(e -> e.name == "wasmtarget.class_id", mod.exports)
    if k === nothing
        add_export!(mod, "wasmtarget.class_id", 0,
                    add_function!(mod, WasmValType[AnyRef], WasmValType[I32], copy(ctx.locals), builder_code(b); name=name))
    else
        local slot = Int(mod.exports[k].idx) - num_imported_funcs(mod) + 1
        mod.functions[slot] = WasmFunction(mod.functions[slot].type_idx, copy(ctx.locals), builder_code(b); name=name)
    end
    return nothing
end

"""
    host_escape_js() -> String

The host's catch of an escape, as a JavaScript expression: a function `(exports, e) => outcome`
that a host calling an export runs on what the call threw. An escaped Julia exception (`e.is(tag)`,
the tag exported as `wasmtarget.exception`) answers `{ throw: 'minified:Class<id>', stack }`: its
class read by the exported reader from the exception the payload carries (`getArg(tag, 0)`, after
any `rethrow(e)` replaced it) and the stack its throw captured (`getArg(tag, 1)`). A reader that
traps answers a trap saying the class could not be read, with the reader's message and stack.
Anything else (a trap, the engine's stack exhaustion, a JS exception) is a trap with its message.
parity(quarantine: WT's export boundary is the host's glue (L156), so the catch dart's `\$invokeMain` makes inside wasm, invoke_main_patch.dart:43-52 (`print(e)`, `print(s)`, rethrow), is made by the host; the class prints as type.dart:344 prints it in a minified build, `minified:Class\$index`)
"""
function host_escape_js()::String
    return "((exports, e) => { " *
           "const tag = exports['wasmtarget.exception']; " *
           "if (e instanceof WebAssembly.Exception && tag && e.is(tag)) { " *
           "const st = e.getArg(tag, 1); const stack = String(st && st.stack || ''); " *
           "let id; try { id = exports['wasmtarget.class_id'](e.getArg(tag, 0)); } " *
           "catch (r) { return { trap: \"the escaped exception's class could not be read: \" + String(r && r.message || r), " *
           "stack: String(r && r.stack || '') }; } " *
           "return { throw: 'minified:Class' + id, stack }; } " *
           "return { trap: String(e && e.message || e), stack: String(e && e.stack || '') }; })"
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
    call!(b, something(_import_func_idx(ctx.mod, "wasmtarget", "trace_enter")))
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
    call!(b, something(_import_func_idx(ctx.mod, "wasmtarget", name)))
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
JL_TRY records the depth of Julia's exception stack at the call (julia.h:2548). A call made with
no host-declared import open is top-level and starts with an empty stack (Julia's host call does,
whatever the previous call did); a re-entrant one, from inside a host-declared import, starts
with its caller's stack, the top that import's call saved at its slot (emit_direct_call!). The
entry is a prologue: it sets the top, null when the count of open host-declared imports is 0 or
the module has no count, else `\$import_tops[count - 1]`, then calls the inner with its
parameters, the results leaving on the stack. It has no try and no local: an escape passes it
untouched, its payload exact (L145), and nothing is restored on the way out; a stale top lives
only until the next point that reads it, the next entry, an import's normal return, or a landing,
which takes its top by identity. The inner keeps its own name; this one is
"<export name> (export)", as dart names an import "<name> (import)" (functions.dart:141).
formal(dev/formal/ExceptionStack.tla): every escape leaves the stack as Julia's host leaves it (TopLevelReset, EntryTakesSlot), except dev/MARCH.md 13.17 H11 (MCExceptionStackReraiseSharedBroken); H8 is outside the model.
parity(quarantine: Julia's per-task exception stack outlives a call, and the host is the catching frame that starts a top-level call with an empty stack and a re-entrant one with its caller's, julia.h:2548 jl_excstack_state; dart's catch state is lexical, code_generator.dart:2966 visitRethrow.)
"""
function emit_export_entry!(mod::WasmModule, inner_idx::Integer, name::String)::UInt32
    local ft = mod.types[Int(mod.functions[Int(inner_idx) - num_imported_funcs(mod) + 1].type_idx) + 1]::FuncType
    local top = ensure_exception_top_global!(mod)
    local cell = ConcreteRef(exc_cell_type!(mod), true)
    local count = host_imports_open_global(mod)
    local b = InstrBuilder(copy(ft.params), copy(ft.results); func_name="emit_export_entry!", mod=mod)
    if count === nothing
        ref_null!(b, cell.type_idx)
    else
        # a re-entrant call starts with the top at its open import's call
        global_get!(b, count); num!(b, Opcode.I32_EQZ)
        if_!(b; results=WasmValType[cell])
        ref_null!(b, cell.type_idx)
        else_!(b)
        local tops = ensure_import_tops_global!(mod)
        global_get!(b, tops)
        global_get!(b, count); i32_const!(b, 1); num!(b, Opcode.I32_SUB)
        array_get!(b, import_tops_type!(mod))
        end_block!(b)
    end
    global_set!(b, top)
    for i in 0:length(ft.params) - 1; local_get!(b, i); end
    call!(b, inner_idx)
    finish_function!(b)
    return add_function!(mod, ft.params, ft.results, WasmValType[], builder_code(b); name=generated_function_name(:export_entry, name))
end

"""
    ensure_host_imports_open!(mod)

At compile setup, in a module that holds a host-declared import (_is_host_declared_import), the
import of the count of its open calls, `wasmtarget.host_imports_open`, a mutable i32 the host's
glue answers and writes (host_glue_js); no wasm code writes it. An imported global precedes every
defined one (add_global_import!), so a module that already defines a global when it is set up is
refused here, naming the import and the global. A framework that defines its own globals before
compiling calls this itself, after declaring its host imports and before its first global, as it
calls ensure_provenance_imports! before its first definition.
parity(quarantine: Julia's host call starts with an empty exception stack and a re-entrant one with its caller's; a call is re-entrant iff a host import that may call back is open, which only the host observes on every exit, its glue's finally (host_glue_js); dart has no exception stack.)
"""
function ensure_host_imports_open!(mod::WasmModule)::Nothing
    global_named(mod, "\$host_imports_open") === nothing || return nothing
    local host = findfirst(_is_host_declared_import, mod.imports)
    host === nothing && return nothing
    local defined = findfirst(g -> g isa WasmGlobalDef, mod.globals)
    defined === nothing || throw(ArgumentError(
        "the host-declared import $(mod.imports[host].module_name).$(mod.imports[host].field_name) needs the " *
        "imported count wasmtarget.host_imports_open, which must precede the module's defined global " *
        "$(defined - 1)$(mod.globals[defined].name === nothing ? "" : " ($(mod.globals[defined].name))"): " *
        "call WasmTarget.ensure_host_imports_open!(mod) after declaring the host imports and before defining any global"))
    add_global_import!(mod, "wasmtarget", "host_imports_open", I32, true; name="\$host_imports_open")
    return nothing
end

"""
    host_imports_open_global(mod) -> Union{Nothing, UInt32}

`\$host_imports_open`, the imported count of open calls of host-declared imports, found by its
name (ensure_host_imports_open! imports it at compile setup); `nothing` in a module with no
host-declared import, where every export call is top-level. WT's own runtime imports
(HOST_RUNTIME, a traced compile's `wasmtarget.trace_*`) never call an export back and are not
counted. A host-declared import added after the setup has no count, and is refused.
parity(quarantine: Julia's host call starts with an empty exception stack and a re-entrant one with its caller's; a call is re-entrant iff a host import that may call back is open, which only the host observes on every exit, its glue's finally (host_glue_js); dart has no exception stack.)
"""
function host_imports_open_global(mod::WasmModule)::Union{Nothing,UInt32}
    local g = global_named(mod, "\$host_imports_open")
    g === nothing || return g
    local host = findfirst(_is_host_declared_import, mod.imports)
    host === nothing || throw(ArgumentError(
        "the host-declared import $(mod.imports[host].module_name).$(mod.imports[host].field_name) was added " *
        "after compile setup, which imports their count wasmtarget.host_imports_open (ensure_host_imports_open!)"))
    return nothing
end

# an imported function the host declared, not one of WT's own runtime imports
# parity(quarantine: Julia's host call starts with an empty exception stack and a re-entrant one with its caller's; only a host-declared import can call an export back.)
_is_host_declared_import(imp)::Bool =
    imp.kind == 0x00 && imp.module_name != "wasmtarget" &&
    !any(((m, f, _),) -> m == imp.module_name && f == imp.field_name, HOST_RUNTIME)

# `\$import_tops`'s array: a mutable array of exception-stack tops, nullable
# parity(quarantine: Julia's J2: a re-entrant call starts with its caller's stack, the stack at the open import's call; dart's call counts nothing, instructions.dart:947)
import_tops_type!(mod::WasmModule)::UInt32 =
    add_type!(mod, ArrayType(FieldType(ConcreteRef(exc_cell_type!(mod), true), true)))

"""
    ensure_import_tops_global!(mod) -> global_idx

`\$import_tops`, the top of Julia's exception stack at each open call of a host-declared import,
indexed by the count at the call: null until the first such call, then an array grown to hold
the index (the save helper, import_tops_save!). Defined once and found by its name.
parity(quarantine: Julia's J2: a re-entrant call starts with its caller's stack, the stack at the open import's call; dart's call counts nothing, instructions.dart:947)
"""
function ensure_import_tops_global!(mod::WasmModule)::UInt32
    local g = global_named(mod, "\$import_tops")
    g === nothing || return g
    local arr = import_tops_type!(mod)
    return add_global!(mod, ConcreteRef(arr, true), true, nothing; name="\$import_tops")
end

"""
    import_tops_save!(mod) -> func_idx

The one helper a call of a host-declared import calls first: it stores the top of Julia's
exception stack at index count of `\$import_tops`, growing the array to (count + 1) * 2 slots
(array.new_default and array.copy) when it is null or too short. Defined once per module, at the
first such call, and found by its name, "import_tops save".
parity(quarantine: Julia's J2: a re-entrant call starts with its caller's stack, the stack at the open import's call; dart's call counts nothing, instructions.dart:947)
"""
function import_tops_save!(mod::WasmModule)::UInt32
    local i = findfirst(f -> f.name == generated_function_name(:import_tops_save), mod.functions)
    i === nothing || return UInt32(num_imported_funcs(mod) + i - 1)
    local count = something(host_imports_open_global(mod))
    local top = ensure_exception_top_global!(mod)
    local tops = ensure_import_tops_global!(mod)
    local arr = import_tops_type!(mod)
    local arr_ref = ConcreteRef(arr, true)
    local b = InstrBuilder(WasmValType[], WasmValType[]; func_name="import_tops_save!", mod=mod)
    local grown = builder_add_local!(b, arr_ref)
    # the array's length, 0 while it is null
    global_get!(b, tops); ref_is_null!(b)
    if_!(b; results=WasmValType[I32])
    i32_const!(b, 0)
    else_!(b)
    global_get!(b, tops); array_len!(b)
    end_block!(b)
    # too short for index count: a new array of (count + 1) * 2 slots, the old one copied in
    global_get!(b, count); num!(b, Opcode.I32_LE_U)
    if_!(b)
    global_get!(b, count); i32_const!(b, 1); num!(b, Opcode.I32_ADD); i32_const!(b, 1); num!(b, Opcode.I32_SHL)
    array_new_default!(b, arr)
    local_set!(b, grown)
    global_get!(b, tops); ref_is_null!(b); num!(b, Opcode.I32_EQZ)
    if_!(b)
    local_get!(b, grown); i32_const!(b, 0)
    global_get!(b, tops); i32_const!(b, 0)
    global_get!(b, tops); array_len!(b)
    array_copy!(b, arr, arr)
    end_block!(b)
    local_get!(b, grown); global_set!(b, tops)
    end_block!(b)
    global_get!(b, tops)
    global_get!(b, count)
    global_get!(b, top)
    array_set!(b, arr)
    finish_function!(b)
    return add_function!(mod, WasmValType[], WasmValType[], WasmValType[arr_ref], builder_code(b);
                         name=generated_function_name(:import_tops_save))
end

"""
    emit_direct_call!(b, mod, func_idx) -> b

A direct call of the function a registry or a host binding names, its arguments on the stack. A
call of a host-declared import first stores the top of Julia's exception stack at its slot, index
count of `\$import_tops` (import_tops_save!), where an export the host calls back from inside it
takes it (emit_export_entry!); after a normal return, the glue's finally having brought the count
back to its value at the call, it sets the top from that slot. The count is the host's glue's
(host_glue_js): no wasm code writes it.
formal(dev/formal/ExceptionStack.tla): ImportCall and ImportReturn (ReturnRestores).
parity(quarantine: Julia's J2: a re-entrant call starts with its caller's stack, the stack at the open import's call; dart's call counts nothing, instructions.dart:947)
"""
function emit_direct_call!(b::InstrBuilder, mod::WasmModule, func_idx::Integer)::InstrBuilder
    local imports = filter(imp -> imp.kind == 0x00, mod.imports)
    local host = Int(func_idx) < length(imports) && _is_host_declared_import(imports[Int(func_idx) + 1])
    host && call!(b, import_tops_save!(mod))
    call!(b, func_idx)
    if host
        local cell = ConcreteRef(exc_cell_type!(mod), true)
        local tops = ensure_import_tops_global!(mod)
        global_get!(b, tops)
        global_get!(b, something(host_imports_open_global(mod)))
        array_get!(b, import_tops_type!(mod))
        global_set!(b, ensure_exception_top_global!(mod))
    end
    return b
end

"""
    exc_saved_local!(ctx, enter_idx) -> local

The local where try region `enter_idx` keeps the top of the exception stack when it is
entered, its depth: its pop_exception restores it, as Julia's enter records
jl_excstack_state and pop_exception calls jl_restore_excstack.
parity(quarantine: Julia's exception stack is task state that a region's enter and pop_exception save and restore; dart binds each catch's exception to its own locals (code_generator.dart:958 visitTryCatch).)
"""
function exc_saved_local!(ctx::AbstractCompilationContext, enter_idx::Int)::Int
    return get!(ctx.exc_saved_locals, enter_idx) do
        allocate_local!(ctx, ConcreteRef(exc_cell_type!(ctx.mod), true))
    end
end


