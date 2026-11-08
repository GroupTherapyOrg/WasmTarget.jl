# The dart packages and the libraries dart imports under a prefix at the pin, each a Julia module, as
# DART_MODULES (src/julia/parity.jl) maps every dart file to one: WasmBuilder for wasm_builder, with
# IR for the ir library builder/ and serialize/ import `as ir`; Dart2Wasm for dart2wasm, with Util
# and JS for `util.dart as util` and `js/runtime_generator.dart as js`. A name dart spells `p.X` is
# `P.X` where P is bound: each module binds its package and the package modules it uses. Each module's
# imports are written by `julia dev/skeleton.jl write` between its markers, all of them: the src/julia
# names, Base's and Core's unexported names and the package modules its files use as globals, so no lane
# edits an import by hand (L210 refuses a block that differs and an import outside every block).

# dart's runtime library, the @patch libraries a program is compiled with (RUNTIME_FILES), its ports
# Julia methods compiled into every closed world (RUNTIME_ROOTS, below)
@quarantine pin"pkg/dart2wasm/lib/target.dart:156 WasmTarget.extraRequiredLibraries" "Julia has no per-file namespace; dart's patch libraries, the program's runtime (pkg/dart2wasm/lib/target.dart:156 WasmTarget.extraRequiredLibraries), are a module" Core.Module module Runtime
# ---- Runtime's imports, written by dev/skeleton.jl write ----
import ..@parity, ..WasmArray, ..WasmExternRef, ..WasmI16, ..WasmI32, .._wasm_only,
       ..jl_is_tuple_type, ..jl_is_type_type, ..jl_to_typeof, ..jl_typetagis, ..wasm_array_length,
       ..wasm_array_new, ..wasm_array_read, ..wasm_array_read_unsigned, ..wasm_array_write!,
       ..wasm_string_codeunit
# ---- end of Runtime's imports ----
end
# ---- the runtime's roots, written by dev/skeleton.jl write ----
@quarantine pin"pkg/vm/lib/transformations/type_flow/native_code.dart:144 PragmaEntryPointsVisitor.visitProcedure" "dart roots every procedure carrying @pragma('wasm:entry-point') in every program (pkg/vm/lib/transformations/type_flow/native_code.dart:144 PragmaEntryPointsVisitor.visitProcedure), each Runtime port whose anchored dart declaration carries it, and Julia's runtime functions the code generator calls (julia/src/rtutils.c:189 jl_bounds_error), which every Julia process links whole, where Julia differs: libjulia has no demand to keep one out, so every one is a root" Core.Symbol const RUNTIME_ROOTS::Tuple{Vararg{Tuple{Tuple{Vararg{Symbol}},Symbol}}} = (
    ((:Runtime,), :Error__throw_with_current_stack_trace),
    ((:Runtime,), :StackTrace_current),
    ((:Runtime,), :_InterfaceType_class_id),
    ((:Runtime,), :_TypeError__throw_as_check_error),
    ((:Runtime,), :_as_interface_subtype0),
    ((:Runtime,), :_as_subtype),
    ((:Runtime,), :_is_interface_subtype0),
    ((:Runtime,), :_is_nullability_check),
    ((:Runtime,), :_is_subtype),
    ((:Runtime,), :_is_type_subtype),
    ((:Runtime,), :_no_substitution_index),
    ((:Runtime,), :_type_row_displacement_offsets),
    ((:Runtime,), :_type_row_displacement_subst_table),
    ((:Runtime,), :_type_row_displacement_table),
    ((:Runtime,), :_verify_optimized_type_check),
    ((), :divti3),
    ((), :jl_egal),
    ((), :jl_egal_host_references),
    ((), :jl_subtype_typeof),
    ((), :jl_to_typeof),
    ((), :jl_typechk_type),
    ((), :modti3),
    ((), :throw_atomic_error),
    ((), :throw_bounds_error),
    ((), :throw_divide_error),
    ((), :throw_host_reference_egal),
    ((), :throw_invalid_memory_size),
    ((), :throw_method_error),
    ((), :throw_out_of_memory),
    ((), :throw_undef_ref_error),
    ((), :udiv128by64to64),
    ((), :udiv128by64to64default),
    ((), :udivmodti4),
    ((), :udivti3),
    ((), :umodti3),
    ((), :wasm_egal),
)
# ---- end of the runtime's roots ----

@quarantine pin"precedent(julia: base/ryu/Ryu.jl:1 Ryu)" "Julia has no per-file namespace; the ports of LLVM's WebAssembly backend, the second oracle (dev/LEDGER.md D42), and of the compiler-rt builtins its libcalls name are one module, as Julia keeps its port of the Ryu algorithm, an external code base (Ulf Adams' reference C implementation), in one module of its own (precedent(julia: base/ryu/Ryu.jl:1 Ryu))" Core.Module module LLVM
# ---- LLVM's imports, written by dev/skeleton.jl write ----
import ..@parity, ..BLOCK, ..BLOCK_TYPE_CATCH, ..BLOCK_TYPE_EXNREF, ..BLOCK_TYPE_RESULTS,
       ..BLOCK_TYPE_VOID, ..BR, ..BR_IF, ..BR_TABLE, ..BR_UNLESS, ..CATCH, ..CATCH_ALL_REF,
       ..CONST_I32, ..COPY, ..END_BLOCK, ..END_LOOP, ..END_TRY_TABLE, ..Internal, ..LOOP,
       ..LinkedHashMap, ..LinkedHashSet, ..MOBlock, ..MOImm, ..MachineFunction, ..MachineInstr,
       ..MachineOperand, ..NirHandlers, ..NirPhi, ..NirStmt, ..PriorityQueue, ..STMTS, ..THROW_REF,
       ..TRY_TABLE, ..UNREACHABLE, ..WASM_OPCODE_CATCH, ..WASM_OPCODE_CATCH_ALL_REF,
       ..create_label_register!, ..create_machine_basic_block!, ..get_block_numbered,
       ..get_prev_node, ..is_barrier, ..is_terminator, ..machine_function, ..post_order,
       ..pq_empty, ..pq_pop!, ..pq_push!, ..recompute_domtree!, ..reject!, ..renumber_blocks!,
       ..sd_get, ..strongly_connected_components, ..terminators
import ..WasmBuilder
# ---- end of LLVM's imports ----
end

@quarantine unpinned "Julia has no per-file namespace; dart's wasm_builder package is a module" Core.Module module WasmBuilder
# ---- WasmBuilder's imports, written by dev/skeleton.jl write ----
import ..@dart_export, ..@parity, ..@quarantine, ..AbstractInstructionsBuilder, ..AbstractModule,
       ..AbstractModuleBuilder, ..Internal, ..InvalidModule, ..Late, ..LinkedHashMap,
       ..LinkedHashSet, ..Unported, ..reject!, ..strongly_connected_components
import Base: @nospecializeinfer
# ---- end of WasmBuilder's imports ----
@quarantine unpinned "dart's builder and serializer import ir under the prefix ir; a prefix is a module in Julia" Core.Module module IR
# ---- IR's imports, written by dev/skeleton.jl write ----
import ...@closed, ...@dart_export, ...@parity, ...AbstractModule, ...Internal, ...InvalidModule,
       ...Late, ...LinkedHashMap, ...Unported, ...reject!
import ..WasmBuilder
# ---- end of IR's imports ----
end
end

@quarantine pin"pkg/dart2wasm/lib/dart2wasm.dart:298 main" "Julia has no per-file namespace; dart's dart2wasm package, its library entered at pkg/dart2wasm/lib/dart2wasm.dart:298 main, is a module" Core.Module module Dart2Wasm
# ---- Dart2Wasm's imports, written by dev/skeleton.jl write ----
import ..@closed, ..@exhaustive, ..@parity, ..@quarantine, ..AbstractClosures,
       ..AbstractDispatchTable, ..AbstractLambda, ..BLOCK, ..BLOCK_TYPE_CATCH, ..BLOCK_TYPE_EXNREF,
       ..BLOCK_TYPE_RESULTS, ..BLOCK_TYPE_VOID, ..BR, ..BR_IF, ..BR_TABLE, ..BR_UNLESS, ..CATCH,
       ..CATCH_ALL_REF, ..CONST_I32, ..COPY, ..ClassField, ..ClosedWorld, ..END_BLOCK, ..END_LOOP,
       ..END_TRY_TABLE, ..EXCEPTION_TAG_EXPORT, ..FieldAccessSite, ..FieldReference,
       ..FieldReferenceKind_getter, ..FieldReferenceKind_initializer, ..FieldReferenceKind_setter,
       ..FunctionTarget, ..ImmutableWasmArray, ..InstanceConstant, ..Internal, ..InvalidModule,
       ..JS_INTEROP_LIBRARY, ..LOOP, ..Late, ..LinkedHashMap, ..LinkedHashSet, ..MOImm,
       ..MachineInstr, ..NirArgument, ..NirBody, ..NirBoundscheck, ..NirCFunction, ..NirCall,
       ..NirConst, ..NirEnter, ..NirForeignCall, ..NirForeignImport, ..NirGCPreserveBegin,
       ..NirGCPreserveEnd, ..NirGlobal, ..NirGlobalRead, ..NirGoto, ..NirGotoIfNot, ..NirInvoke,
       ..NirInvokeModify, ..NirLeave, ..NirLoopInfo, ..NirNew, ..NirNothing, ..NirPhi, ..NirPhiC,
       ..NirPi, ..NirPopException, ..NirReturn, ..NirSSA, ..NirStmt, ..NirTheException,
       ..NirThrowUndefIfNot, ..NirUnreachable, ..NirUpsilon, ..NirValue, ..NirWorld,
       ..NoCounterpart, ..Reference, ..STANDALONE_EMBEDDER_MODULE, ..STMTS, ..SelectorReference,
       ..THROW_REF, ..TRY_TABLE, ..TreeNode_no_offset, ..UNREACHABLE, ..UnionFind, ..Unported,
       ..Unquarantined, ..WASM_OPCODE_CATCH, ..WASM_OPCODE_CATCH_ALL_REF, ..WASM_STORAGE_TYPES,
       ..WasmArray, ..WasmArrayLiteral, ..WasmExternRef, ..WasmF32, ..WasmF64, ..WasmI16,
       ..WasmI32, ..WasmI64, ..WasmI8, ..build_nir, ..class_implemented_types,
       ..class_instance_fields, ..class_is_abstract, ..class_is_set_field, ..class_superclass,
       ..closed_world_classes, ..concrete_class_ids, ..concrete_classes, ..constant_unmade,
       ..divti3, ..egal_by_identity, ..field_may_be_null, ..field_selector_calls,
       ..holds_reference, ..is_interface_class_type, ..jl_egal, ..jl_egal_host_references,
       ..jl_is_tuple_type, ..jl_is_type_type, ..jl_subtype_typeof, ..jl_to_typeof, ..jl_typetagis,
       ..modti3, ..nir_argument_type, ..nir_binding_is_constant, ..nir_binding_value,
       ..nir_body_of, ..nir_callee, ..nir_carries_data, ..nir_const_type, ..nir_foreign_import,
       ..nir_foreign_operands, ..nir_invoke_target, ..nir_method_nargs, ..nir_operands,
       ..nir_parameter_types, ..nir_runtime_member, ..nir_tuple_type, ..nir_used_statements,
       ..nir_value_operands, ..nir_value_type, ..nir_vararg_call_tuple, ..nir_vararg_packing,
       ..no_counterpart_rejection, ..open_tuple_holds, ..record_member_tests, ..reject!,
       ..run_time_type_gap, ..run_time_type_test!, ..run_time_type_value!, ..run_wasm_opt,
       ..sd_get, ..throw_atomic_error, ..throw_bounds_error, ..throw_divide_error,
       ..throw_host_reference_egal, ..throw_invalid_memory_size, ..throw_method_error,
       ..throw_out_of_memory, ..throw_undef_ref_error, ..told_by_class, ..tuple_record_arity,
       ..tuple_record_class, ..type_expand_integer, ..type_value_unmade, ..udivti3, ..uf_add!,
       ..uf_find!, ..uf_union!, ..umodti3, ..wasm_array_length, ..wasm_array_new,
       ..wasm_array_read, ..wasm_array_read_unsigned, ..wasm_array_write!, ..wasm_egal,
       ..wasm_memory_copy!, ..wasm_memory_fill!, ..wasm_memory_string, ..wasm_memory_unset!,
       ..wasm_string_alloc, ..wasm_string_codeunit, ..wasm_string_copy!, ..wasm_string_length,
       ..wasm_string_memory
import Base: @nospecializeinfer
import Core: MethodInstance
import ..LLVM
import ..Runtime
import ..WasmBuilder
# ---- end of Dart2Wasm's imports ----
@quarantine unpinned "dart2wasm imports util.dart under the prefix util; a prefix is a module in Julia" Core.Module module Util
# ---- Util's imports, written by dev/skeleton.jl write ----
import ...@parity, ...ClassField, ...Internal, ...NirConst, ...NirWorld, ...nir_body_of,
       ...program_export_name, ...reject!
import ..Dart2Wasm
# ---- end of Util's imports ----
end
@quarantine unpinned "dart2wasm's compile imports js/runtime_generator.dart under the prefix js; a prefix is a module in Julia" Core.Module module JS
# ---- JS's imports, written by dev/skeleton.jl write ----
import ...@parity, ...Internal, ...JS_STRING_BUILTINS_MODULE, ...nir_js_sites, ...reject!
import ..Dart2Wasm
# ---- end of JS's imports ----
end
end

