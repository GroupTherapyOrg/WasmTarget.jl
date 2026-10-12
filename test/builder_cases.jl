# The builder's per-instruction checks as programs (dev/CHARTER.md C7): each program either
# throws at the emitting call (an invalid one, which wasm-tools rejects) or builds a module (a
# valid one, which wasm-tools accepts). `W` is the module holding the builder: WasmTarget in
# test/module_builder_validation.jl, or src/builder/*.jl loaded alone in test/parity_ratchet.jl
# (L164, L165, L166 and L151 run these rows there, in seconds).
#
# builder_cases(W) -> Vector of (row, id, expect, program): `expect` is the exception type the
# program's last call throws, or :valid for a program that returns its finished module.

function builder_cases(W::Module)
    VT = W.WasmValType
    fin(m, ps, rs, b) = (W.finish_function!(b); W.add_function!(m, b; name="f"); m)
    cases = Any[]
    add(row, id, expect, program) = push!(cases, (row = row, id = id, expect = expect, program = program))

    # A3B3: one subtype relation. funcref is not (ref null $sig)
    add("a", "A3B3", W.StackImbalanceError, () -> begin
        m = W.WasmModule(); sig = W.add_type!(m, W.FuncType(VT[], VT[W.I32]))
        b = W.InstrBuilder(VT[W.FuncRef], VT[W.I32]; mod=m); W.local_get!(b, 0)
        W.call_ref!(b, sig) end)
    # A3B3: two distinct function types are unrelated
    add("b", "A3B3", W.StackImbalanceError, () -> begin
        m = W.WasmModule(); f = W.add_type!(m, W.FuncType(VT[], VT[W.I32]))
        g = W.add_type!(m, W.FuncType(VT[], VT[W.I64]))
        b = W.InstrBuilder(VT[W.ConcreteRef(UInt32(f), true)], VT[W.I64]; mod=m); W.local_get!(b, 0)
        W.call_ref!(b, g) end)
    # A3B3: a type index the module does not define is invalid, never guessed a struct
    add("c", "A3B3", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); W.add_struct_type!(m, W.FieldType[])
        b = W.InstrBuilder(VT[], VT[W.StructRef]; mod=m)
        W.builder_add_local!(b, W.ConcreteRef(UInt32(99), true)) end)
    # A3B4: i8 is a storage type, not a value type: no local holds it
    add("d", "A3B4", MethodError, () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(VT[], VT[]; mod=m)
        W.builder_add_local!(b, W.I8) end)
    # A3B6: ref.null pushes the nullable reference, which a non-null result does not take
    add("e", "A3B6", W.StackImbalanceError, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, W.FieldType[]); r = W.ConcreteRef(UInt32(st), false)
        b = W.InstrBuilder(VT[], VT[r]; mod=m); W.ref_null!(b, st)
        W.finish_function!(b) end)
    # A3B6: struct.new pops the struct's own fields
    add("f", "A3B6", W.StackImbalanceError, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, [W.FieldType(W.I64, true)])
        b = W.InstrBuilder(VT[], VT[]; mod=m); W.i32_const!(b, 1)
        W.struct_new!(b, st) end)
    # A3B6, valid: struct.new of a packed field pops its unpacked i32
    add("g", "A3B6", :valid, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, [W.FieldType(W.I8, true)])
        b = W.InstrBuilder(VT[], VT[]; mod=m); W.i32_const!(b, 1); W.struct_new!(b, st); W.drop!(b)
        fin(m, [], [], b) end)
    # A3B7: num! emits no instruction that takes an immediate
    add("h", "A3B7", ArgumentError, () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(VT[], VT[]; mod=m)
        W.num!(b, W.Opcode.I32_CONST) end)
    # A3B8, valid: extern.convert_any of a non-null reference is non-null
    add("i", "A3B8", :valid, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, W.FieldType[]); p = W.ConcreteRef(UInt32(st), false)
        b = W.InstrBuilder(VT[p], VT[W.NonNullExternRef]; mod=m); W.local_get!(b, 0); W.extern_convert_any!(b)
        fin(m, [p], [W.NonNullExternRef], b) end)
    # A3B2: ref.test's operand is under its target's top type
    add("j", "A3B2", W.StackImbalanceError, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, W.FieldType[])
        b = W.InstrBuilder(VT[W.FuncRef], VT[]; mod=m); W.local_get!(b, 0)
        W.ref_test!(b, st, false) end)
    # A3B2: ref.cast's operand is a reference
    add("k", "A3B2", W.StackImbalanceError, () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(VT[], VT[]; mod=m); W.i32_const!(b, 0)
        W.ref_cast!(b, W.StructRef, false) end)
    # A3B2: a local the builder does not hold
    add("l", "A3B2", W.StackImbalanceError, () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(VT[], VT[]; mod=m); W.i32_const!(b, 1)
        W.local_set!(b, 7) end)
    # A3B9 (the spec's rule, which dart leaves to the engine, checked as the else-less if is):
    # struct.set writes a mutable field
    add("m", "A3B9", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, [W.FieldType(W.I32, false)]); p = W.ConcreteRef(UInt32(st), false)
        b = W.InstrBuilder(VT[p], VT[]; mod=m); W.local_get!(b, 0); W.i32_const!(b, 1)
        W.struct_set!(b, st, 0) end)
    # A3B9: array.new_default takes an array type
    add("n", "A3B9", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, W.FieldType[])
        b = W.InstrBuilder(VT[], VT[]; mod=m); W.i32_const!(b, 4)
        W.array_new_default!(b, st) end)
    # A3B9 (the spec's rule): struct.new_default needs every field defaultable
    add("o", "A3B9", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, W.FieldType[])
        st2 = W.add_struct_type!(m, [W.FieldType(W.ConcreteRef(UInt32(st), false), true)])
        b = W.InstrBuilder(VT[], VT[]; mod=m)
        W.struct_new_default!(b, st2) end)
    # A3B9 (the spec's rule): array.set writes a mutable array
    add("p", "A3B9", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); a = W.add_array_type!(m, W.I32, false); p = W.ConcreteRef(UInt32(a), false)
        b = W.InstrBuilder(VT[p], VT[]; mod=m); W.local_get!(b, 0); W.i32_const!(b, 0); W.i32_const!(b, 1)
        W.array_set!(b, a) end)
    # A3B9: array.new_data makes a primitive array (dart asserts elementType.isPrimitive)
    add("q", "A3B9", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); st = W.add_struct_type!(m, W.FieldType[])
        a = W.add_array_type!(m, W.ConcreteRef(UInt32(st), true), true)
        seg = W.add_passive_data_segment!(m, UInt8[1, 2, 3, 4])
        b = W.InstrBuilder(VT[], VT[]; mod=m); W.i32_const!(b, 0); W.i32_const!(b, 1)
        W.array_new_data!(b, a, seg) end)
    # A3B10: a call names a function the module defines
    add("r", "A3B10", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); e = W.InstrBuilder(VT[], VT[]; mod=m); fin(m, [], [], e)
        b = W.InstrBuilder(VT[], VT[]; mod=m)
        W.call!(b, 999) end)
    # A3B5: every builder has its module
    add("s", "A3B5", UndefKeywordError, () -> W.InstrBuilder(VT[], VT[W.I64]; func_name="g"))
    # A15B3: a fragment that shares its function's locals carries its function's parameters (one
    # with none types local 0 as the function's first declared local, not its parameter)
    add("t", "A15B3", ArgumentError, () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(VT[W.I32], VT[]; mod=m); W.builder_add_local!(b, W.I64)
        F = W.InstrBuilder(; mod=m, locals=b.locals, fragment=true); W.local_get!(F, 0); W.drop!(F)
        W.append_builder!(b, F) end)
    # A15B4: trunc_sat! emits a saturating truncation, never another FC instruction (0x0b is
    # memory.fill)
    add("u", "A15B4", ArgumentError, () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(VT[], VT[]; mod=m); W.f64_const!(b, 1.0)
        W.trunc_sat!(b, 0x0b) end)
    # A15B5: an imported function is named where it is imported (the name section drops none)
    add("v", "A15B5", ArgumentError, () -> W.WasmImport("host", "f", 0x00, UInt32(0), ""))
    return cases
end

# The module's bodies as programs (dev/CHARTER.md C7): every function body and global
# initializer is a builder the module made, its locals initialized before they are read, its
# returns its function's results, its initializer a constant expression. Rows a-j of
# test/module_builder_validation.jl's testset "115b: every body is a builder the module made"
# (its row k compiles, so it is there alone); the ratchet runs these over src/builder alone
# (L167, L168).
function body_cases(W::Module)
    VT = W.WasmValType
    cases = Any[]
    add(row, id, expect, program) = push!(cases, (row = row, id = id, expect = expect, program = program))
    # a struct type, its non-null reference, and a builder of `params -> results` in a fresh module
    setup(params=VT[], results=VT[]) = (m = W.WasmModule(); st = W.add_struct_type!(m, W.FieldType[]);
        r = W.ConcreteRef(UInt32(st), false); (m, st, r, W.InstrBuilder(params, VT[(t === :r ? r : t) for t in results]; mod=m)))
    # A13B1: a non-defaultable local read before any set
    add("a", "A13B1", W.StackImbalanceError, () -> begin
        m, st, r, b = setup(VT[], Any[:r]); i = W.builder_add_local!(b, r)
        W.local_get!(b, i) end)
    # A13B1: a set inside a block does not initialize after its end
    add("b", "A13B1", W.StackImbalanceError, () -> begin
        m, st, r, b = setup(VT[], Any[:r]); i = W.builder_add_local!(b, r)
        W.block!(b); W.struct_new_default!(b, st); W.local_set!(b, i); W.end_block!(b)
        W.local_get!(b, i) end)
    # A13B1: set in the then arm only, read in the else arm
    add("c", "A13B1", W.StackImbalanceError, () -> begin
        m, st, r, b = setup(VT[W.I32]); i = W.builder_add_local!(b, r)
        W.local_get!(b, 0); W.if_!(b); W.struct_new_default!(b, st); W.local_set!(b, i); W.else_!(b)
        W.local_get!(b, i) end)
    # A13B1: a fragment reads an unset non-defaultable local, appended where it was never set
    add("d", "A13B1", W.StackImbalanceError, () -> begin
        m, st, r, b = setup(); i = W.builder_add_local!(b, r)
        F = W.InstrBuilder(VT[], VT[]; mod=m, locals=b.locals, fragment=true)
        W.local_get!(F, i); W.drop!(F)
        W.append_builder!(b, F) end)
    # A13B1, valid: F sets the local at its outer level, G reads it; F then G appended
    add("e", "A13B1", :valid, () -> begin
        m, st, r, b = setup(); i = W.builder_add_local!(b, r)
        F = W.InstrBuilder(VT[], VT[]; mod=m, locals=b.locals, fragment=true)
        W.struct_new_default!(F, st); W.local_set!(F, i)
        G = W.InstrBuilder(VT[], VT[]; mod=m, locals=b.locals, fragment=true)
        W.local_get!(G, i); W.drop!(G)
        W.append_builder!(b, F); W.append_builder!(b, G)
        W.finish_function!(b); W.add_function!(m, b; name="f"); m end)
    # A3B1: a body with no results returns an f64; put in a function [] -> [i64]
    add("f", "A3B1", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); idx = W.define_function!(m, VT[], VT[W.I64]; name="f")
        b = W.InstrBuilder(; mod=m); W.f64_const!(b, 1.0); W.return_!(b); W.finish_function!(b)
        W.fill_function!(m, idx, b) end)
    # A3B16: a function [] -> [i32] filled with a body built [i64] -> [i64]
    add("g", "A3B16", W.ModuleValidationError, () -> begin
        m = W.WasmModule(); idx = W.define_function!(m, VT[], VT[W.I32]; name="f")
        b = W.InstrBuilder(VT[W.I64], VT[W.I64]; mod=m); W.local_get!(b, 0); W.finish_function!(b)
        W.fill_function!(m, idx, b) end)
    # A4B1, A11E6: an i32 initializes (ref $st)
    add("h", "A4B1/A11E6", W.StackImbalanceError, () -> begin
        m, st, r, _ = setup(); g, init = W.define_global!(m, r, false)
        W.i32_const!(init, 0); W.finish_function!(init) end)
    # A4B1: an initializer holding a call (a constant expression is required)
    add("i", "A4B1", W.StackImbalanceError, () -> begin
        m, st, r, fb = setup(VT[], Any[:r]); W.struct_new_default!(fb, st); W.finish_function!(fb)
        fidx = W.add_function!(m, fb; name="f")
        g, init = W.define_global!(m, r, false)
        W.call!(init, fidx) end)
    # A4B1: an initializer's global.get of a global defined after it
    add("j", "A4B1", W.StackImbalanceError, () -> begin
        m = W.WasmModule(); g0, init0 = W.define_global!(m, W.I32, false)
        g1 = W.add_global!(m, W.I32, false, 7)
        W.global_get!(init0, g1) end)
    return cases
end

# Dead code as programs (dev/CHARTER.md C7): an instruction emitted while the code is unreachable
# is dropped, as dart's `_add` drops it (instructions.dart:368 `if (!_reachable) return;`), so the
# builder holds only instructions wasm validates where they stand. `end`, `else` and `catch` of a
# frame entered reachable restore reachability before they are recorded (instructions.dart:851,
# :783, :815); a frame entered in dead code is dropped whole. Each program returns its finished
# builder and `want`, the kinds of the instructions it must hold; the ratchet runs these over
# src/builder alone (L172), test/module_builder_validation.jl with wasm-tools.
function dead_cases(W::Module)
    VT = W.WasmValType
    cases = Any[]
    add(row, id, want, program) = push!(cases, (row = row, id = id, expect = :holds, want = want, program = program))
    done(m, b) = (W.finish_function!(b); W.add_function!(m, b; name="f"); b)
    # A15B1: after unreachable, an f64 under i32.eqz (wasm-tools rejects it where it stands)
    add("a", "A15B1", [:Unreachable, :End], () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(; mod=m)
        W.unreachable!(b); W.f64_const!(b, 0); W.num!(b, W.Opcode.I32_EQZ); W.drop!(b)
        done(m, b) end)
    # a block entered in dead code is dropped with its end
    add("b", "A15B1", [:Unreachable, :End], () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(; mod=m)
        W.unreachable!(b); W.block!(b); W.i64_const!(b, 1); W.drop!(b); W.end_block!(b)
        done(m, b) end)
    # br makes the rest of its block dead; the block's end, entered reachable, is recorded
    add("c", "A15B1", [:Block, :Br, :End, :I32Const, :Drop, :End], () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(; mod=m)
        l = W.block!(b); W.br!(b, l); W.f64_const!(b, 0); W.drop!(b); W.end_block!(b)
        W.i32_const!(b, 2); W.drop!(b)
        done(m, b) end)
    # return and throw are recorded, what follows each is not; else of an if entered reachable is
    add("d", "A15B1", [:I32Const, :If, :Return, :Else, :Nop, :End, :End], () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(; mod=m)
        W.i32_const!(b, 1); W.if_!(b); W.return_!(b); W.f32_const!(b, 0); W.else_!(b); W.nop!(b)
        W.end_block!(b)
        done(m, b) end)
    # a catch of a try entered reachable is recorded after a throw in the body
    add("e", "A15B1", [:BeginTry, :Throw, :CatchLegacy, :End, :End], () -> begin
        m = W.WasmModule(); tag = W.add_tag!(m, W.add_type!(m, W.FuncType(VT[], VT[])))
        b = W.InstrBuilder(; mod=m)
        W.try_legacy!(b); W.throw_!(b, tag); W.i64_const!(b, 3); W.drop!(b); W.catch_legacy!(b, tag)
        W.end_block!(b)
        done(m, b) end)
    # a fragment appended where its function's code is unreachable adds nothing
    add("f", "A15B1", [:Unreachable, :End], () -> begin
        m = W.WasmModule(); b = W.InstrBuilder(; mod=m)
        F = W.InstrBuilder(; mod=m, locals=b.locals, fragment=true)
        W.f64_const!(F, 0); W.drop!(F)
        W.unreachable!(b); W.append_builder!(b, F)
        done(m, b) end)
    return cases
end

# run one case: `true` when it throws what it expects, (a valid one) returns its module, or (a
# dead_cases row) returns a builder holding exactly the instruction kinds it wants
function builder_case_holds(W::Module, c)::Bool
    if c.expect === :holds
        local b = c.program()
        return b isa W.InstrBuilder && Symbol[nameof(typeof(i)) for i in b.instrs] == c.want
    end
    if c.expect === :valid
        local m = c.program()
        return m isa W.WasmModule && !isempty(W.to_bytes(m))
    end
    try
        c.program()
    catch e
        return e isa c.expect
    end
    return false
end
