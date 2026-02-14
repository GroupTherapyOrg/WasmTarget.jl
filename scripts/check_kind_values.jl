using JuliaSyntax

# Print the UInt16 values for all relevant Kind values
for k in [K"Float", K"Float32", K"Char", K"String", K"CmdString", K"Bool", K"Integer", K"BinInt", K"OctInt", K"HexInt", K"Identifier", K"CmdMacroName", K"ErrorInvalidOperator", K"error", K"block", K"wrapper", K"baremodule", K"var"]
    val = Base.bitcast(UInt16, k)
    println("  K\"$(JuliaSyntax.untokenize(k))\" = UInt16($val) = i32($val)")
end
