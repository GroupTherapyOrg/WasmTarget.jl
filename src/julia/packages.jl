# The dart packages and the libraries dart imports under a prefix at the pin, each a Julia module, as
# DART_MODULES (src/julia/parity.jl) maps every dart file to one: WasmBuilder for wasm_builder, with
# IR for the ir library builder/ and serialize/ import `as ir`; Dart2Wasm for dart2wasm, with Util
# and JS for `util.dart as util` and `js/runtime_generator.dart as js`. A name dart spells `p.X` is
# `P.X` where P is bound: each module binds the macros, its package and the package modules it uses.

@quarantine "Julia has no per-file namespace; dart's wasm_builder package is a module" Core.Module module WasmBuilder
import ..@parity, ..@unported, ..@quarantine, ..@closed, ..@exhaustive
# ported code rejects where dart throws (src/julia/reject.jl)
import ..reject!, ..Internal, ..Unported, ..InvalidModule
# dart's `late final` fields (src/julia/late.jl); dart's insertion-ordered Map and Set
# (src/julia/linked_hash_map.jl); package:collection's stronglyConnectedComponents
# (src/julia/collection.jl); the forward declarations of IR.Module, ModuleBuilder and
# InstructionsBuilder (src/julia/forward.jl)
import ..Late, ..LinkedHashMap, ..LinkedHashSet, ..strongly_connected_components
import ..AbstractModule, ..AbstractModuleBuilder, ..AbstractInstructionsBuilder
@quarantine "dart's builder and serializer import ir under the prefix ir; a prefix is a module in Julia" Core.Module module IR
import ...@parity, ...@unported, ...@closed, ...@exhaustive
import ...reject!, ...Internal, ...Unported, ...InvalidModule, ...Late, ...LinkedHashMap, ...LinkedHashSet, ...AbstractModule
import ..WasmBuilder
end
end

@quarantine "Julia has no per-file namespace; dart's dart2wasm package is a module" Core.Module module Dart2Wasm
import ..@parity, ..@unported, ..@quarantine, ..@closed, ..@exhaustive
# ported code rejects where dart throws (src/julia/reject.jl); dart's `late final` fields (src/julia/late.jl);
# dart's insertion-ordered Map and Set (src/julia/linked_hash_map.jl)
import ..reject!, ..Internal, ..Unported, ..Unquarantined, ..Late, ..LinkedHashMap, ..LinkedHashSet
# vm's UnionFind, which closures.dart imports (src/julia/union_find.jl)
import ..UnionFind, ..uf_add!, ..uf_find!, ..uf_union!
# the forward declaration of Closures, which Lambda points back to (src/julia/forward.jl)
import ..AbstractClosures
# the program, as Julia's trim verifier accepts it and the NIR reads it (src/julia/subset.jl, nir.jl),
# and its classes, Julia's answers where dart reads a Kernel Class (src/julia/classes.jl)
import ..ClosedWorld, ..NirBody, ..NirWorld, ..NoCounterpart, ..build_nir, ..closed_world_classes, ..class_superclass, ..class_is_abstract,
       ..class_implemented_types, ..ClassField, ..class_instance_fields,
       ..NirStmt, ..NirCall, ..NirInvoke, ..NirNew, ..NirForeignCall, ..NirBoundscheck, ..NirGCPreserveBegin,
       ..NirGCPreserveEnd, ..NirLeave, ..NirPopException, ..NirTheException, ..NirLoopInfo, ..NirThrowUndefIfNot,
       ..NirCFunction, ..NirInvokeModify, ..NirGoto, ..NirGotoIfNot, ..NirReturn, ..NirUnreachable, ..NirPhi, ..NirPi,
       ..NirEnter, ..NirUpsilon, ..NirPhiC, ..NirNothing, ..NirGlobalRead,
       ..NirValue, ..NirSSA, ..NirArgument, ..NirGlobal, ..NirConst
# Kernel's constants by the Kernel table's rows (src/julia/constant.jl)
import ..Constant, ..InstanceConstant
# what the code generator reads from a body (src/julia/nir.jl)
import ..TreeNode_no_offset, ..nir_used_statements, ..nir_argument_type, ..nir_method_nargs, ..nir_body_of,
       ..nir_invoke_target, ..nir_callee
import ..WasmBuilder
@quarantine "dart2wasm imports util.dart under the prefix util; a prefix is a module in Julia" Core.Module module Util
import ...@parity, ...@unported, ...@closed, ...@exhaustive
import ...reject!, ...Internal, ...Unported
# a Kernel type Julia has no counterpart for, as stubs name it (src/julia/kernel.jl)
import ...NoCounterpart
import ...WasmBuilder
import ..Dart2Wasm
end
@quarantine "dart2wasm's compile imports js/runtime_generator.dart under the prefix js; a prefix is a module in Julia" Core.Module module JS
import ...@parity, ...@unported, ...@closed, ...@exhaustive
import ...reject!, ...Internal, ...Unported
# a Kernel type Julia has no counterpart for, as stubs name it (src/julia/kernel.jl)
import ...NoCounterpart
import ...WasmBuilder
import ..Dart2Wasm
end
end
