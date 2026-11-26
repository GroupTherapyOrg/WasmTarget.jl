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
import ..@parity, ..WasmArray, ..WasmExternRef, ..WasmI16, ..WasmI32, ..WasmI8, .._wasm_only,
       ..jl_is_tuple_type, ..jl_is_type_type, ..jl_to_typeof, ..jl_typetagis,
       ..set_owner_identity_hash_field, ..wasm_array_length, ..wasm_array_new, ..wasm_array_read,
       ..wasm_array_read_unsigned, ..wasm_array_write!, ..wasm_string_codeunit
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
    ((:Runtime,), :string_from_ascii_bytes),
    ((), :_jl_symbol),
    ((), :divti3),
    ((), :jl_egal),
    ((), :jl_egal_host_references),
    ((), :jl_error),
    ((), :jl_gc_add_finalizer_),
    ((), :jl_subtype_typeof),
    ((), :jl_to_typeof),
    ((), :jl_type_error),
    ((), :jl_typechk_type),
    ((), :jl_undefined_var_error),
    ((), :modti3),
    ((), :throw_atomic_error),
    ((), :throw_bounds_error),
    ((), :throw_divide_error),
    ((), :throw_field_error),
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
       ..CONST_I32, ..COPY, ..END_BLOCK, ..END_LOOP, ..END_TRY_TABLE, ..IMPLICIT_DEF, ..Internal,
       ..LOOP, ..LinkedHashMap, ..LinkedHashSet, ..MOBlock, ..MOImm, ..MachineFunction,
       ..MachineInstr, ..MachineOperand, ..NirHandlers, ..NirPhi, ..NirStmt, ..NirUpsilon,
       ..PriorityQueue, ..REGISTER_INCOMING, ..REGISTER_LABEL, ..REGISTER_VALUE, ..STMTS,
       ..THROW_REF, ..TRY_TABLE, ..UNREACHABLE, ..WASM_OPCODE_CATCH, ..WASM_OPCODE_CATCH_ALL_REF,
       ..create_label_register!, ..create_machine_basic_block!, ..get_block_numbered,
       ..get_prev_node, ..is_barrier, ..is_terminator, ..machine_function, ..nir_used_statements,
       ..post_order, ..pq_empty, ..pq_pop!, ..pq_push!, ..recompute_domtree!, ..reject!,
       ..renumber_blocks!, ..sd_get, ..strongly_connected_components, ..terminators
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
       ..CATCH_ALL_REF, ..CONST_I32, ..COPY, ..ClassField, ..ClosedWorld, ..CompileStatics,
       ..ConstantOwner, ..END_BLOCK, ..END_LOOP, ..END_TRY_TABLE, ..EXCEPTION_TAG_EXPORT,
       ..FieldAccessSite, ..FieldReference, ..FieldReferenceKind_getter,
       ..FieldReferenceKind_initializer, ..FieldReferenceKind_setter, ..FixedArity,
       ..FunctionTarget, ..HeldStrings, ..IMPLICIT_DEF, ..ImmutableWasmArray, ..InstanceConstant,
       ..Internal, ..InvalidModule, ..JS_INTEROP_LIBRARY, ..KIND_ENTRY_GAP, ..KIND_ENTRY_UNDEF,
       ..KindFieldTable, ..LOOP, ..Late, ..LinkedHashMap, ..LinkedHashSet, ..MOImm, ..MachineInstr,
       ..NirArgument, ..NirBinding, ..NirBody, ..NirBoundscheck, ..NirCFunction, ..NirCall,
       ..NirConst, ..NirEnter, ..NirForeignCall, ..NirForeignImport, ..NirGCPreserveBegin,
       ..NirGCPreserveEnd, ..NirGlobal, ..NirGlobalRead, ..NirGoto, ..NirGotoIfNot, ..NirInvoke,
       ..NirInvokeModify, ..NirLeave, ..NirLoopInfo, ..NirNew, ..NirNothing, ..NirPhi, ..NirPhiC,
       ..NirPi, ..NirPopException, ..NirReturn, ..NirSSA, ..NirStmt, ..NirTheException,
       ..NirThrowUndefIfNot, ..NirUnreachable, ..NirUpsilon, ..NirValue, ..NirWorld,
       ..NoCounterpart, ..ProgramError, ..REGISTER_VALUE, ..RecordArity, ..RecordCheckRecordType,
       ..RecordConstructor, ..RecordEquals, ..RecordHashCode, ..RecordMasqueradedRuntimeType,
       ..RecordMember, ..RecordMemberReference, ..RecordRuntimeType, ..RecordToString, ..Reference,
       ..Rejection, ..RejectionError, ..RunTimeArity, ..STANDALONE_EMBEDDER_MODULE, ..STMTS,
       ..SelectorReference, ..StringObject, ..THROW_REF, ..TRY_TABLE, ..TYPENAME_CACHES,
       ..TreeNode_no_offset, ..TupleRecordArray, ..UNREACHABLE, ..UnionFind, ..Unported,
       ..Unquarantined, ..WASM_OPCODE_CATCH, ..WASM_OPCODE_CATCH_ALL_REF, ..WASM_STORAGE_TYPES,
       ..WasmArray, ..WasmArrayLiteral, ..WasmEqRef, ..WasmExternRef, ..WasmF32, ..WasmF64,
       ..WasmI16, ..WasmI32, ..WasmI64, ..WasmI8, .._jl_symbol, .._jt_show, .._unowned_memory,
       ..applicable_cache, ..applies_tuple, ..apply_type_cache, ..boxed_record_class, ..build_nir,
       ..class_implemented_types, ..class_instance_fields, ..class_is_abstract,
       ..class_is_set_field, ..class_superclass, ..classes_without_field, ..closed_world_classes,
       ..concrete_class_ids, ..concrete_classes, ..constant_unmade, ..datatype_hash,
       ..declared_type_unheld, ..divti3, ..egal_by_identity, ..emit_phi_incoming!,
       ..field_may_be_null, ..field_receiver_classes, ..field_selector_calls,
       ..generic_memory_elsize, ..holds_reference, ..identity_hash_field_holder, ..image_object_id,
       ..image_slot!, ..is_interface_class_type, ..jl_datatype_hash_of, ..jl_datatype_same_name,
       ..jl_egal, ..jl_egal_host_references, ..jl_egal_unionall, ..jl_error,
       ..jl_gc_add_finalizer_, ..jl_genericmemory_owner_arm, ..jl_is_tuple_type, ..jl_is_type_type,
       ..jl_new_unionall, ..jl_nothing_subtype_var_gap, ..jl_object_id_identity_arm,
       ..jl_subtype_typeof, ..jl_to_typeof, ..jl_type_error, ..jl_type_hash, ..jl_type_hash_gap,
       ..jl_type_identity_premise, ..jl_type_unionall, ..jl_types_equal, ..jl_types_equal_gap,
       ..jl_typetagis, ..jl_undefined_var_error, ..julia_text, ..kind_field_table,
       ..managed_pointer, ..memory_constant_object, ..memory_owner, ..memoryref_union_classes,
       ..modti3, ..new_struct_classes, ..nir_argument_type, ..nir_binding,
       ..nir_binding_initializer, ..nir_binding_is_constant, ..nir_binding_value, ..nir_body_of,
       ..nir_callee, ..nir_carries_data, ..nir_compile_time_operand, ..nir_const_type,
       ..nir_foreign_import, ..nir_foreign_operands, ..nir_invoke_target, ..nir_libjulia_func,
       ..nir_method_nargs, ..nir_operands, ..nir_parameter_types, ..nir_runtime_member,
       ..nir_tuple_type, ..nir_used_statements, ..nir_value_operands, ..nir_value_type,
       ..nir_vararg_call_tuple, ..nir_vararg_packing, ..no_counterpart_rejection,
       ..open_tuple_holds, ..primitive_value_type, ..record_arities, ..record_member_tests,
       ..record_typeof, ..record_typeof_message, ..record_typeof_unmade, ..register_constant_class,
       ..reject!, ..run_time_type_gap, ..run_time_type_test!, ..run_time_type_value!,
       ..run_wasm_opt, ..sd_get, ..set_owner_identity_hash_field, ..throw_atomic_error,
       ..throw_bounds_error, ..throw_divide_error, ..throw_field_error,
       ..throw_invalid_memory_size, ..throw_method_error, ..throw_out_of_memory,
       ..throw_undef_ref_error, ..told_by_class, ..top_held_classes, ..tuple_record_arity,
       ..tuple_record_class, ..tuple_type_rows, ..type_expand_integer, ..type_promote_integer,
       ..type_value_entries, ..type_value_unmade, ..typename_cache_pruned, ..typename_cache_unread,
       ..types_equal_cache, ..types_equal_identity_premise, ..udivti3, ..uf_add!, ..uf_find!,
       ..uf_union!, ..umodti3, ..unionall_class, ..wasm_array_length, ..wasm_array_new,
       ..wasm_array_read, ..wasm_array_read_unsigned, ..wasm_array_write!, ..wasm_egal,
       ..wasm_memory_copy!, ..wasm_memory_fill!, ..wasm_memory_overlaps, ..wasm_memory_string,
       ..wasm_memory_unset!, ..wasm_pointer_based, ..wasm_pointer_offset, ..wasm_pointer_same_base,
       ..wasm_string_alloc, ..wasm_string_codeunit, ..wasm_string_copy!, ..wasm_string_length,
       ..wasm_string_memory, ..wasm_string_write!, ..wasm_symbol_child, ..wasm_symbol_hash,
       ..wasm_symbol_name, ..wasm_symbol_new, ..wasm_symbol_set_child!
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

