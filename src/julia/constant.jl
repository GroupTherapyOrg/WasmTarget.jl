# Kernel's constants, by the Kernel table's rows (the lead's ruling, 2026-10-28): a Kernel
# `Constant` is the NIR's own literal, `NirConst` (src/julia/nir.jl), Julia's `Core.Const` of the
# value, two constants one exactly when Julia calls their values egal (===); each specific Kernel
# constant is its Julia value's type, so a port's visitor takes the value (Nothing, Bool, the
# integers, the floats, String, Symbol, a tuple, a Type) and an `InstanceConstant` is a `NirConst`
# of any other object. These two names are the rows the ports spell; the Kernel table's file takes
# them when it lands.

"""Kernel's `Constant`: the NIR's literal, `NirConst`."""
@quarantine "Kernel's Constant is the NIR's literal; the Kernel table's row, by its Kernel name" WasmTarget.NirConst const Constant = NirConst

"""Kernel's `InstanceConstant`: a `NirConst` of an object that is no other kind's value."""
@quarantine "Kernel's InstanceConstant is the NIR's literal of an object; the Kernel table's row, by its Kernel name" WasmTarget.NirConst const InstanceConstant = NirConst
