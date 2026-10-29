# The dart packages and the libraries dart imports under a prefix at the pin, each a Julia module, as
# DART_MODULES (src/julia/parity.jl) maps every dart file to one: WasmBuilder for wasm_builder, with
# IR for the ir library builder/ and serialize/ import `as ir`; Dart2Wasm for dart2wasm, with Util
# and JS for `util.dart as util` and `js/runtime_generator.dart as js`. A name dart spells `p.X` is
# `P.X` where P is bound: each module binds its package and the package modules it uses. Each module's
# imports of src/julia are written by `julia dev/skeleton.jl write` between its markers: exactly the
# src/julia names its files use, so no lane edits them by hand (L210 refuses a block that differs).

# dart's runtime library, the @patch libraries a program is compiled with (RUNTIME_FILES), its ports
# Julia methods compiled into every closed world (src/julia/subset.jl RUNTIME_ENTRY_POINTS)
@quarantine "Julia has no per-file namespace; dart's patch libraries, the program's runtime, are a module" Core.Module module Runtime
# ---- the src/julia names Runtime's files use, written by dev/skeleton.jl write ----
import ..@parity
# ---- end of Runtime's src/julia names ----
end

@quarantine "Julia has no per-file namespace; LLVM's WebAssembly backend, the second oracle (dev/LEDGER.md D42), is a module" Core.Module module LLVM
# ---- the src/julia names LLVM's files use, written by dev/skeleton.jl write ----
import ..@parity, ..BLOCK, ..BLOCK_TYPE_CATCH, ..BLOCK_TYPE_EXNREF, ..BLOCK_TYPE_RESULTS,
       ..BLOCK_TYPE_VOID, ..BR, ..BR_IF, ..BR_TABLE, ..BR_UNLESS, ..CATCH, ..CATCH_ALL_REF,
       ..CONST_I32, ..COPY, ..END_BLOCK, ..END_LOOP, ..END_TRY_TABLE, ..Internal, ..LOOP,
       ..LinkedHashMap, ..LinkedHashSet, ..MOBlock, ..MOImm, ..MachineFunction, ..MachineInstr,
       ..MachineOperand, ..NirHandlers, ..NirPhi, ..NirStmt, ..PriorityQueue, ..STMTS, ..THROW_REF,
       ..TRY_TABLE, ..UNREACHABLE, ..WASM_OPCODE_CATCH, ..WASM_OPCODE_CATCH_ALL_REF,
       ..create_label_register!, ..create_machine_basic_block!, ..get_block_numbered,
       ..get_prev_node, ..is_barrier, ..is_terminator, ..machine_function, ..post_order,
       ..pq_empty, ..pq_pop!, ..pq_push!, ..recompute_domtree!, ..reject!, ..renumber_blocks!,
       ..strongly_connected_components, ..terminators
# ---- end of LLVM's src/julia names ----
end

@quarantine "Julia has no per-file namespace; dart's wasm_builder package is a module" Core.Module module WasmBuilder
# ---- the src/julia names WasmBuilder's files use, written by dev/skeleton.jl write ----
import ..@dart_export, ..@parity, ..@quarantine, ..AbstractInstructionsBuilder, ..AbstractModule,
       ..AbstractModuleBuilder, ..Internal, ..InvalidModule, ..Late, ..LinkedHashMap,
       ..LinkedHashSet, ..Unported, ..reject!, ..strongly_connected_components
# ---- end of WasmBuilder's src/julia names ----
# a method serving every subtype alike is inferred once, not once per caller's type (a compile's first-use cost)
import Base: @nospecializeinfer
@quarantine "dart's builder and serializer import ir under the prefix ir; a prefix is a module in Julia" Core.Module module IR
# ---- the src/julia names IR's files use, written by dev/skeleton.jl write ----
import ...@closed, ...@dart_export, ...@parity, ...AbstractModule, ...Internal, ...InvalidModule,
       ...Late, ...LinkedHashMap, ...Unported, ...reject!
# ---- end of IR's src/julia names ----
import ..WasmBuilder
end
end

@quarantine "Julia has no per-file namespace; dart's dart2wasm package is a module" Core.Module module Dart2Wasm
# ---- the src/julia names Dart2Wasm's files use, written by dev/skeleton.jl write ----
import ..@closed, ..@exhaustive, ..@parity, ..@quarantine, ..@unported, ..AbstractClosures,
       ..AbstractDispatchTable, ..AbstractLambda, ..BLOCK, ..BLOCK_TYPE_CATCH, ..BLOCK_TYPE_EXNREF,
       ..BLOCK_TYPE_RESULTS, ..BLOCK_TYPE_VOID, ..BR, ..BR_IF, ..BR_TABLE, ..BR_UNLESS, ..CATCH,
       ..CATCH_ALL_REF, ..CONST_I32, ..COPY, ..ClassField, ..ClosedWorld, ..END_BLOCK, ..END_LOOP,
       ..END_TRY_TABLE, ..EXCEPTION_TAG_EXPORT, ..FieldReference, ..FieldReferenceKind_getter,
       ..FieldReferenceKind_initializer, ..FieldReferenceKind_setter, ..ImmutableWasmArray,
       ..InstanceConstant, ..Internal, ..LOOP, ..Late, ..LinkedHashMap, ..LinkedHashSet, ..MOImm,
       ..MachineInstr, ..NirArgument, ..NirBody, ..NirBoundscheck, ..NirCFunction, ..NirCall,
       ..NirConst, ..NirEnter, ..NirForeignCall, ..NirGCPreserveBegin, ..NirGCPreserveEnd,
       ..NirGlobal, ..NirGlobalRead, ..NirGoto, ..NirGotoIfNot, ..NirInvoke, ..NirInvokeModify,
       ..NirLeave, ..NirLoopInfo, ..NirNew, ..NirNothing, ..NirPhi, ..NirPhiC, ..NirPi,
       ..NirPopException, ..NirReturn, ..NirSSA, ..NirStmt, ..NirTheException,
       ..NirThrowUndefIfNot, ..NirUnreachable, ..NirUpsilon, ..NirValue, ..NirWorld,
       ..NoCounterpart, ..Reference, ..STMTS, ..THROW_REF, ..TRY_TABLE, ..TreeNode_no_offset,
       ..UNREACHABLE, ..UnionFind, ..Unported, ..Unquarantined, ..WASM_OPCODE_CATCH,
       ..WASM_OPCODE_CATCH_ALL_REF, ..WASM_STORAGE_TYPES, ..WasmArray, ..WasmArrayLiteral,
       ..WasmF32, ..WasmF64, ..WasmI32, ..WasmI64, ..WasmI8, .._KINDS, ..build_nir,
       ..class_implemented_types, ..class_instance_fields, ..class_is_abstract, ..class_superclass,
       ..closed_world_classes, ..egal_by_identity, ..nir_argument_type, ..nir_binding_is_constant,
       ..nir_binding_value, ..nir_body_of, ..nir_callee, ..nir_carries_data, ..nir_const_type,
       ..nir_invoke_target, ..nir_method_nargs, ..nir_operands, ..nir_runtime_member,
       ..nir_tuple_type, ..nir_used_statements, ..nir_value_type, ..no_counterpart_rejection,
       ..reject!, ..run_wasm_opt, ..throw_bounds_error, ..throw_divide_error,
       ..throw_undef_ref_error, ..uf_add!, ..uf_find!, ..uf_union!, ..wasm_string_alloc,
       ..wasm_string_codeunit, ..wasm_string_copy!, ..wasm_string_length
# ---- end of Dart2Wasm's src/julia names ----
# a dispatcher over every NIR kind is inferred once, not once per kind of node (a compile's first-use cost)
import Base: @nospecializeinfer
# a match over the Kernel table's Reference names its MethodInstance kind by its name
import Core: MethodInstance
import ..LLVM
import ..Runtime
import ..WasmBuilder
@quarantine "dart2wasm imports util.dart under the prefix util; a prefix is a module in Julia" Core.Module module Util
# ---- the src/julia names Util's files use, written by dev/skeleton.jl write ----
import ...@parity, ...ClassField, ...Internal, ...NirConst, ...NirWorld, ...nir_body_of,
       ...nir_host_import, ...program_export_name, ...reject!
# ---- end of Util's src/julia names ----
import ...WasmBuilder
import ..Dart2Wasm
end
@quarantine "dart2wasm's compile imports js/runtime_generator.dart under the prefix js; a prefix is a module in Julia" Core.Module module JS
# ---- the src/julia names JS's files use, written by dev/skeleton.jl write ----
import ...@parity, ...Internal, ...reject!
# ---- end of JS's src/julia names ----
import ...WasmBuilder
import ..Dart2Wasm
end
end

