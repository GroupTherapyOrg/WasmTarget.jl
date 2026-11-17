# THE generator of the runner's fixtures (spec v16 X1, v17 Y1, Y6), run by hand when a fixture changes, never at run or test
# time (wasm-tools is no judge, D10): test/fixtures/runner_calls.tsv and runner_raw.tsv from runner.wat, each call with the raw wire
# it must produce, written here by hand from the wat's own semantics (never read from a runner's output)
import base64, subprocess, sys, os
T = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
wasm = subprocess.run(["wasm-tools", "parse", f"{T}/test/fixtures/runner.wat"], capture_output=True, check=True).stdout
calls = [  # (name, entry, args, the exact raw wire, ms left out)
    ("i32 typemin", "i32", ["i32:80000000"], "ret i32 80000000"),
    ("i32 all ones", "i32", ["i32:ffffffff"], "ret i32 ffffffff"),
    ("i64 typemin", "i64", ["i64:8000000000000000"], "ret i64 8000000000000000"),
    ("i64 typemax", "i64", ["i64:7fffffffffffffff"], "ret i64 7fffffffffffffff"),
    ("i64 past 2^53", "i64", ["i64:0020000000000001"], "ret i64 0020000000000001"),
    ("f32 signaling NaN through", "f32", ["f32:7f800001"], "ret f32 7f800001"),
    ("f32 quiet NaN payload through", "f32", ["f32:ffc00001"], "ret f32 ffc00001"),
    ("f32 -0.0 through", "f32", ["f32:80000000"], "ret f32 80000000"),
    ("f64 signaling NaN through", "f64", ["f64:7ff0000000000001"], "ret f64 7ff0000000000001"),
    ("f64 quiet NaN payload through", "f64", ["f64:fff8000000000123"], "ret f64 fff8000000000123"),
    ("f64 -0.0 through", "f64", ["f64:8000000000000000"], "ret f64 8000000000000000"),
    ("f32 signaling NaN made in wasm", "snan32", [], "ret f32 ffa00000"),
    ("f64 signaling NaN made in wasm", "snan64", [], "ret f64 7ff4000000000001"),
    ("f32 signaling NaN argument read in wasm", "bits32", ["f32:7f800001"], "ret i32 7f800001"),
    ("f64 signaling NaN argument read in wasm", "bits64", ["f64:7ff0000000000001"], "ret i64 7ff0000000000001"),
    ("a nested aggregate's own module", "nest", ["i64:0000000000000007"], "ret ref -"),
    ("a nested aggregate's i64 leaf", "nest_i64", ["i64:0000000000000007", "i64:0000000000000001"], "ret i64 0000000000000007"),
    ("a nested aggregate's -0.0 leaf", "nest_f64", ["i64:0000000000000007", "i64:0000000000000001"], "ret f64 8000000000000000"),
    ("a nested aggregate's null field", "nest_null", ["i64:0000000000000007", "i64:0000000000000001"], "ret i32 00000001"),
    ("an empty String's ncodeunits", "ncu", ["i64:0000000000000000"], "ret i64 0000000000000000"),
    ("a non-ASCII String's ncodeunits", "ncu", ["i64:0000000000000001"], "ret i64 0000000000000002"),
    ("a non-ASCII String's first codeunit", "cu", ["i64:0000000000000001"], "ret i32 000000c3"),
    ("a non-ASCII String's second codeunit", "cu", ["i64:0000000000000002"], "ret i32 000000a9"),
    ("no value", "void", [], "ret void -"),
    ("a null reference", "null", [], "ret null -"),
    ("a non-null reference", "ref", [], "ret ref -"),
    ("a wasm exception under the module's tag", "throws", ["i32:00000001"], "exc [object WebAssembly.Exception]"),
    ("a trap", "traps", [], "err trap: unreachable"),
    ("a fresh instance, first call", "count", [], "ret i32 00000001"),
    ("a fresh instance, second call", "count", [], "ret i32 00000001"),
]
hdr = ("# The runner's fixtures (spec v16 X1), the judge's (G5): the run's first input, ahead of every measurement's calls,\n"
       "# in the compile records' grammar (`module <label> <key> <base64>`, `call <label> <j> <entry> <args...>`); the module is\n"
       "# test/fixtures/runner.wat assembled, each call's exact raw wire in test/fixtures/runner_raw.tsv, in order.\n")
with open(f"{T}/test/fixtures/runner_calls.tsv", "w") as f:
    f.write(hdr)
    f.write(f"module\tfixtures\t-\t{base64.b64encode(wasm).decode()}\n")
    for name, entry, args, _ in calls:
        f.write("\t".join(["call", "fixtures", "0", entry, *args]) + "\n")
with open(f"{T}/test/fixtures/runner_raw.tsv", "w") as f:
    f.write("# Each call of test/fixtures/runner_calls.tsv, in order: its name and the exact raw wire it must produce\n"
            "# (test/verdict.jl's grammar, a `ret` line's ms left out), written by hand from test/fixtures/runner.wat.\n")
    for name, _, _, raw in calls:
        f.write(f"{name}\t{raw}\n")
print(len(calls), "calls", len(wasm), "bytes")
# the patched fixtures (spec v17 Y1): runner_patch.wat assembled, each sentinel's offset found (it occurs exactly once),
# written as test/fixtures/runner_patch.tsv: the module, then each slot `slot <export> <offset> <width> <kind>`, the
# raw wire's kind its export returns (p_add's: i64, its argument plus the slot's bits, mod 2^64), then each export that
# holds no slot, `fixed <export>` (its wire test/verdict.jl's PATCH_FIXED)
patch = subprocess.run(["wasm-tools", "parse", f"{T}/test/fixtures/runner_patch.wat"], capture_output=True, check=True).stdout
slots = [("p_i32", 0x7f935724, 4, "i32"), ("p_i64", 0x7ff1357246813579, 8, "i64"), ("p_f32", 0x7fa46813, 4, "f32"),
         ("p_f64", 0x7ff2468135792468, 8, "f64"), ("p_add", 0x7ff3579246813579, 8, "i64")]
with open(f"{T}/test/fixtures/runner_patch.tsv", "w") as f:
    f.write("# The runner's patched fixtures (spec v17 Y1), the judge's (G5): runner_patch.wat assembled (its base64), and each\n"
            "# slot's export, byte offset, width and the raw wire's kind, and each export of no slot (a trap, a throw);\n"
            "# dev/climb/measure.py run_input draws each slot's bits a run and writes them at the offset. Generated by\n"
            "# test/fixtures/make_fixtures.py.\n")
    f.write(f"module\t{base64.b64encode(patch).decode()}\n")
    for name, bits, width, kind in slots:
        needle = bits.to_bytes(width, "little")
        assert patch.count(needle) == 1, (name, patch.count(needle))
        f.write(f"slot\t{name}\t{patch.index(needle)}\t{width}\t{kind}\n")
    for name in ("p_trap", "p_throw"):
        f.write(f"fixed\t{name}\n")
print(len(slots), "slots", len(patch), "bytes")
