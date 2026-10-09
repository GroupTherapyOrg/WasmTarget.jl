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
    fin(m, ps, rs, b) = (W.finish_function!(b);
        W.add_function!(m, VT[ps...], VT[rs...], VT[], W.builder_code(b); name="f"); m)
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
    return cases
end

# run one case: `true` when it throws what it expects, or (a valid one) returns its module
function builder_case_holds(W::Module, c)::Bool
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
