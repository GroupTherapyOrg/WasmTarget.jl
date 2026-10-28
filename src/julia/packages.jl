# The dart packages and the libraries dart imports under a prefix at the pin, each a Julia module, as
# DART_MODULES (src/julia/parity.jl) maps every dart file to one: WasmBuilder for wasm_builder, with
# IR for the ir library builder/ and serialize/ import `as ir`; Dart2Wasm for dart2wasm, with Util
# and JS for `util.dart as util` and `js/runtime_generator.dart as js`. A name dart spells `p.X` is
# `P.X` where P is bound: each module binds the macros, its package and the package modules it uses.

@quarantine "Julia has no per-file namespace; LLVM's WebAssembly backend, the second oracle (dev/LEDGER.md D42), is a module" Core.Module module LLVM
import ..@parity, ..@unported, ..@quarantine, ..@closed, ..@exhaustive
import ..reject!, ..Internal, ..Unported
# LLVM's machine code over Julia's CFG (src/julia/machine.jl)
import ..MachineFunction, ..MachineBasicBlock, ..MachineInstr, ..MachineOperand, ..MOBlock, ..MOImm, ..Opcode,
       ..BLOCK, ..LOOP, ..END_BLOCK, ..END_LOOP, ..BR, ..BR_IF, ..BR_UNLESS, ..BR_TABLE, ..CONST_I32, ..COPY, ..STMTS,
       ..renumber_blocks!, ..create_machine_basic_block!, ..get_prev_node, ..is_terminator, ..is_barrier, ..create_label_register!, ..recompute_domtree!, ..terminators, ..post_order,
       ..BLOCK_TYPE_VOID, ..BLOCK_TYPE_RESULTS, ..PriorityQueue, ..pq_push!, ..pq_pop!, ..pq_empty, ..get_block_numbered, ..machine_function,
       ..LinkedHashMap, ..LinkedHashSet, ..strongly_connected_components
end

@quarantine "Julia has no per-file namespace; dart's wasm_builder package is a module" Core.Module module WasmBuilder
import ..@parity, ..@unported, ..@quarantine, ..@closed, ..@exhaustive
# dart's export directives (src/julia/exports.jl)
import ..@dart_export
# ported code rejects where dart throws (src/julia/reject.jl)
import ..reject!, ..Internal, ..Unported, ..InvalidModule
# dart's `late final` fields (src/julia/late.jl); dart's insertion-ordered Map and Set
# (src/julia/linked_hash_map.jl); package:collection's stronglyConnectedComponents
# (src/julia/collection.jl); the forward declarations of IR.Module, ModuleBuilder and
# InstructionsBuilder (src/julia/forward.jl)
import ..Late, ..LinkedHashMap, ..LinkedHashSet, ..strongly_connected_components
import ..AbstractModule, ..AbstractModuleBuilder, ..AbstractInstructionsBuilder
@quarantine "dart's builder and serializer import ir under the prefix ir; a prefix is a module in Julia" Core.Module module IR
import ...@parity, ...@unported, ...@closed, ...@exhaustive, ...@dart_export
import ...reject!, ...Internal, ...Unported, ...InvalidModule, ...Late, ...LinkedHashMap, ...LinkedHashSet, ...AbstractModule
import ..WasmBuilder
end
end

@quarantine "Julia has no per-file namespace; dart's dart2wasm package is a module" Core.Module module Dart2Wasm
import ..@parity, ..@unported, ..@quarantine, ..@closed, ..@exhaustive
# ported code rejects where dart throws (src/julia/reject.jl); dart's `late final` fields (src/julia/late.jl);
# dart's insertion-ordered Map and Set (src/julia/linked_hash_map.jl)
import ..reject!, ..Internal, ..Unported, ..Unquarantined, ..OutsideSubset, ..Late, ..LinkedHashMap, ..LinkedHashSet
# vm's UnionFind, which closures.dart imports (src/julia/union_find.jl)
import ..UnionFind, ..uf_add!, ..uf_find!, ..uf_union!
# the forward declaration of Closures, which Lambda points back to (src/julia/forward.jl)
import ..AbstractClosures, ..AbstractDispatchTable
# the program, as Julia's trim verifier accepts it and the NIR reads it (src/julia/subset.jl, nir.jl),
# and its classes, Julia's answers where dart reads a Kernel Class (src/julia/classes.jl)
import ..ClosedWorld, ..NirBody, ..NirWorld, ..NoCounterpart, ..build_nir, .._KINDS, ..closed_world_classes, ..class_superclass, ..class_is_abstract,
       ..class_implemented_types, ..ClassField, ..class_instance_fields,
       ..NirStmt, ..NirCall, ..NirInvoke, ..NirNew, ..NirForeignCall, ..NirBoundscheck, ..NirGCPreserveBegin,
       ..NirGCPreserveEnd, ..NirLeave, ..NirPopException, ..NirTheException, ..NirLoopInfo, ..NirThrowUndefIfNot,
       ..NirCFunction, ..NirInvokeModify, ..NirGoto, ..NirGotoIfNot, ..NirReturn, ..NirUnreachable, ..NirPhi, ..NirPi,
       ..NirEnter, ..NirUpsilon, ..NirPhiC, ..NirNothing, ..NirGlobalRead,
       ..NirValue, ..NirSSA, ..NirArgument, ..NirGlobal, ..NirConst
# Kernel's constants by the Kernel table's rows (src/julia/kernel.jl)
import ..Constant, ..InstanceConstant, ..nir_operands
# dart:_wasm's array literal, the runtime type tables' constants (src/julia/wasm_array.jl)
import ..WasmArrayLiteral, ..WasmArray, ..ImmutableWasmArray
# LLVM's machine code over a body's CFG, which the code generator lowers (src/julia/machine.jl), and
# the backend's passes that structure it (src/llvm/target_machine.jl)
import ..LLVM
import ..MachineFunction, ..MachineInstr, ..MOBlock, ..MOImm, ..BLOCK, ..LOOP, ..END_BLOCK, ..END_LOOP, ..BR, ..BR_IF,
       ..BR_UNLESS, ..BR_TABLE, ..CONST_I32, ..COPY, ..STMTS, ..BLOCK_TYPE_RESULTS, ..is_barrier
# what the code generator reads from a body (src/julia/nir.jl)
import ..TreeNode_no_offset, ..nir_used_statements, ..nir_argument_type, ..nir_method_nargs, ..nir_body_of,
       ..nir_invoke_target, ..nir_callee
import ..WasmBuilder
@quarantine "dart2wasm imports util.dart under the prefix util; a prefix is a module in Julia" Core.Module module Util
import ...@parity, ...@unported, ...@closed, ...@exhaustive
import ...reject!, ...Internal, ...Unported
# the Julia types the Kernel table names, as stubs name them (src/julia/kernel.jl)
import ...NoCounterpart, ...NirWorld, ...NirBody, ...ClassField, ...NirValue, ...NirSSA, ...NirArgument,
       ...NirGlobal, ...NirConst, ...NirStmt, ...NirInvoke, ...NirCall, ...NirNew, ...NirGlobalRead,
       ...NirGotoIfNot, ...NirReturn, ...NirGoto, ...NirEnter
import ...WasmBuilder
import ..Dart2Wasm
end
@quarantine "dart2wasm's compile imports js/runtime_generator.dart under the prefix js; a prefix is a module in Julia" Core.Module module JS
import ...@parity, ...@unported, ...@closed, ...@exhaustive
import ...reject!, ...Internal, ...Unported
# the Julia types the Kernel table names, as stubs name them (src/julia/kernel.jl)
import ...NoCounterpart, ...NirWorld, ...NirBody, ...ClassField, ...NirValue, ...NirSSA, ...NirArgument,
       ...NirGlobal, ...NirConst, ...NirStmt, ...NirInvoke, ...NirCall, ...NirNew, ...NirGlobalRead,
       ...NirGotoIfNot, ...NirReturn, ...NirGoto, ...NirEnter
import ...WasmBuilder
import ..Dart2Wasm
end
end

