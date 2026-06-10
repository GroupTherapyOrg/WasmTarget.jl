# ============================================================================
# FuzzCanon — structural (canonicalized-expr) body matching (M6)
# ============================================================================
#
# Replaces raw substring matching for known-gap detection and gap dedup.
# Canonical form: variables erased to □ (call heads and field names kept,
# literals kept), so the same root cause matches across different variable
# names / compositions, while `occursin`-style false hits (a gap body `x`
# matching EVERY program) are impossible — a pure-variable canonical form is
# rejected from match sets.

module FuzzCanon

export canon_str, subtrees, hits_canon, canon_matchable

function _canon(x)
    if x isa Expr
        if x.head === :call && !isempty(x.args) && x.args[1] isa Symbol
            return Expr(:call, x.args[1], map(_canon, x.args[2:end])...)
        end
        return Expr(x.head, map(_canon, x.args)...)
    end
    return x isa Symbol ? :□ : x
end

canon_str(x) = string(_canon(x))

# A canonical form is matchable when it carries STRUCTURE beyond a bare
# variable/literal — otherwise it would match every program.
canon_matchable(x) = x isa Expr

function subtrees(x)
    out = Any[x]
    _walk!(out, x)
    return out
end
function _walk!(out, x)
    x isa Expr || return
    for a in x.args
        a isa QuoteNode && continue
        push!(out, a)
        _walk!(out, a)
    end
end

"""
    hits_canon(body, known::Set{String}) -> Bool

True if any SUBTREE of `body` canonicalizes to a member of `known` — i.e. the
program fails for an already-tracked structural reason.
"""
function hits_canon(body, known::Set{String})
    isempty(known) && return false
    for s in subtrees(body)
        canon_matchable(s) && canon_str(s) in known && return true
    end
    return false
end

end # module FuzzCanon
