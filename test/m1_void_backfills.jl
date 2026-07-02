# parity(M1) ONE LOWERING — void-body coverage (dev/PARITY_MASTER.md phase M1).
#
# The M1 slice-2 flip routes Nothing-returning bodies through the stackifier (the old
# generate_void_flow fast-path is DELETED). Void functions can't be value-differentialed
# (native `nothing` has no wasm counterpart to compare), and their historical failure mode is
# exactly compile-time-invalid wasm or a runtime trap (PURE-314: generate_void_flow left
# single-edge phis at default 0 → array bounds trap). So the gate here is: every shape
# COMPILES (validate=true → wasm-tools + internal validator) and RUNS in Node WITHOUT trap.
# Value-bearing sibling shapes of the same control flow are covered by smoke's controlflow group.

_m1v_cond(n::Int64) = (n > 0 ? nothing : nothing)
_m1v_assign(n::Int64) = (s = 0; if n > 5; s = n; end; nothing)
_m1v_arraywrite(n::Int64) = (v = zeros(Int64, 3); if n > 1; v[1] = n; end; nothing)
_m1v_nested(n::Int64) = (if n > 0; if n > 5; nothing; end; end; nothing)
_m1v_loop(n::Int64) = (i = 0; while i < n; i += 1; end; nothing)  # void+loop (stackified pre-M1 too)
_m1v_loop_cond(n::Int64) = (s = 0; for i in 1:n; if i % 2 == 0; s += i; end; end; nothing)

@testset "M1 void bodies via the one lowering (compile + run, no trap)" begin
    for (name, f, arg) in [
        ("cond", _m1v_cond, Int64(1)),
        ("assign", _m1v_assign, Int64(7)),
        ("arraywrite", _m1v_arraywrite, Int64(3)),
        ("nested", _m1v_nested, Int64(6)),
        ("loop", _m1v_loop, Int64(4)),
        ("loop_cond", _m1v_loop_cond, Int64(5)),
    ]
        # compile validates by default (wasm-tools + internal validator)
        wasm = WasmTarget.compile(f, (Int64,))
        @test wasm isa Vector{UInt8} && !isempty(wasm)
        # Run in Node. A void export returns JS `undefined`, which the runner's JSON reply
        # can't marshal — that artifact means the function RAN TO COMPLETION (a real trap
        # surfaces as "trap"/"RuntimeError"). So: success = clean return OR the
        # undefined-marshal artifact; failure = anything trap-shaped.
        ran_ok = try
            run_wasm_with_imports(wasm, String(nameof(f)), Dict{String,Any}(), arg)
            true
        catch e
            msg = sprint(showerror, e)
            occursin("not valid JSON", msg) && occursin("undefined", msg)
        end
        @test ran_ok
    end
end
