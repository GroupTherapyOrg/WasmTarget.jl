using JuliaSyntax

# Get code_typed for #parse!#73 with Symbol as the rule type
func = getfield(JuliaSyntax, Symbol("#parse!#73"))
sig = Tuple{Symbol, typeof(JuliaSyntax.parse!), JuliaSyntax.ParseStream}
ci = Base.code_typed(func, sig; optimize=true)
if length(ci) > 0
    ir2 = ci[1][1]
    println("Statements in parse!#73: ", length(ir2.code))
    for (i, stmt) in enumerate(ir2.code)
        s = string(stmt)
        if occursin("===", s) || occursin("egal", s) || occursin("parse_toplevel", s) ||
           occursin("parse_stmts", s) || occursin(":all", s) || occursin(":statement", s) ||
           occursin(":atom", s) || occursin("Symbol", s) || occursin("toplevel", s) ||
           occursin("GotoIfNot", s) || occursin("goto", s)
            println("SSA $i: $stmt")
        end
    end
end

# Also check: What does parsestmt ACTUALLY compile to with WasmTarget?
# Does the rule get inlined as :statement, or is it passed dynamically?
println("\n--- Now checking _parse#75 for rule inlining ---")
func2 = getfield(JuliaSyntax, Symbol("#_parse#75"))
sig2 = Tuple{VersionNumber, Bool, Nothing, Int64, Bool, Bool, Base.Pairs{Symbol, Union{}, Nothing, @NamedTuple{}}, typeof(JuliaSyntax._parse), Symbol, Bool, Type{Expr}, String, Int64}
ci2 = Base.code_typed(func2, sig2; optimize=true)
if length(ci2) > 0
    ir3 = ci2[1][1]
    # Look at SSAs around 8 and 151 (from earlier analysis)
    for i in [1,2,3,4,5,6,7,8,9,10,11,12,149,150,151,152,153,154,155]
        if i <= length(ir3.code)
            println("SSA $i: $(ir3.code[i])")
        end
    end
end
