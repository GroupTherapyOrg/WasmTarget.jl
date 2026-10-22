# The dart packages and the libraries dart imports under a prefix at the pin, each a Julia module, as
# DART_MODULES (src/julia/parity.jl) maps every dart file to one: WasmBuilder for wasm_builder, with
# IR for the ir library builder/ and serialize/ import `as ir`; Dart2Wasm for dart2wasm, with Util
# and JS for `util.dart as util` and `js/runtime_generator.dart as js`. A name dart spells `p.X` is
# `P.X` where P is bound: each module binds the macros, its package and the package modules it uses.

@quarantine "Julia has no per-file namespace; dart's wasm_builder package is a module" Core.Module module WasmBuilder
import ..@parity, ..@unported, ..@quarantine
# ported code rejects where dart throws (src/julia/reject.jl)
import ..reject!, ..Internal, ..Unported
@quarantine "dart's builder and serializer import ir under the prefix ir; a prefix is a module in Julia" Core.Module module IR
import ...@parity, ...@unported
import ..WasmBuilder
end
end

@quarantine "Julia has no per-file namespace; dart's dart2wasm package is a module" Core.Module module Dart2Wasm
import ..@parity, ..@unported, ..@quarantine
import ..WasmBuilder
@quarantine "dart2wasm imports util.dart under the prefix util; a prefix is a module in Julia" Core.Module module Util
import ...@parity, ...@unported
import ...WasmBuilder
import ..Dart2Wasm
end
@quarantine "dart2wasm's compile imports js/runtime_generator.dart under the prefix js; a prefix is a module in Julia" Core.Module module JS
import ...@parity, ...@unported
import ...WasmBuilder
import ..Dart2Wasm
end
end
