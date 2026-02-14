#!/usr/bin/env julia
# Compile diagnostic functions to test each step of build_tree for "1+1"
using WasmTarget
using JuliaSyntax
using JuliaSyntax: SyntaxHead, Kind, @K_str, is_trivia, is_leaf, is_error, has_flags, flags, kind, head, byte_range, span, TRIVIA_FLAG, is_identifier, is_operator, parse_julia_literal, normalize_identifier, RedTreeCursor

const RUNTIME_JS = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")

function test_wasm_i64(f, arg_types, func_name::String, test_args...)
    bytes = compile(f, arg_types)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    nfuncs = length(filter(l -> contains(l, "(func"), readlines(`wasm-tools print $tmpf`)))

    valid = try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`; stderr=devnull))
        true
    catch
        false
    end

    if !valid
        println("  $func_name: VALIDATE_FAIL ($nfuncs funcs, $(length(bytes)) bytes)")
        return "VALIDATE_FAIL"
    end

    # Build JS args
    js_args = join(map(test_args) do arg
        if arg isa String
            "await rt.jsToWasmString($(repr(arg)))"
        elseif arg isa Integer
            string(arg)
        else
            string(arg)
        end
    end, ", ")

    runtime_js_path = escape_string(RUNTIME_JS)
    js = """
    import { readFileSync } from 'fs';
    const rc = readFileSync('$(runtime_js_path)', 'utf-8');
    const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
    const rt = new WRT();
    const w = readFileSync('$(escape_string(tmpf))');
    const mod = await rt.load(w, 'test');
    const func = mod.exports['$func_name'];
    if (!func) {
        console.log('EXPORT_NOT_FOUND');
        process.exit(1);
    }
    try {
        const result = func($js_args);
        if (typeof result === 'bigint') {
            console.log(result.toString());
        } else if (result === null || result === undefined) {
            console.log('null');
        } else {
            console.log(JSON.stringify(result));
        }
    } catch (e) {
        console.log('ERROR: ' + e.message);
    }
    """

    js_path = tempname() * ".mjs"
    write(js_path, js)

    result = try
        strip(read(`node $js_path`, String))
    catch
        "CRASH"
    end

    println("  $func_name($test_args): $result ($nfuncs funcs, $(length(bytes)) bytes)")
    return result
end

# ==========================================
# Test 1: String construction from byte array with range indexing
# This tests val_str = String(txtbuf[srcrange]) in parse_julia_literal
# ==========================================
println("=== Test 1: String from byte array with range ===")

function test_string_from_bytes(s::String)
    txtbuf = unsafe_wrap(Vector{UInt8}, s)
    # For "1+1", byte 2 is '+' (0x2B = 43)
    r = UInt32(2):UInt32(2)
    val_str = String(txtbuf[r])
    # Return the first byte of val_str as verification
    return Int64(codeunit(val_str, 1))
end

test_wasm_i64(test_string_from_bytes, (String,), "test_string_from_bytes", "1+1")

# ==========================================
# Test 2: normalize_identifier on "+"
# ==========================================
println("\n=== Test 2: normalize_identifier ===")

function test_normalize_id(s::String)
    result = normalize_identifier(s)
    # Return 1 if result is same string (ASCII fast path)
    return result === s ? Int64(1) : Int64(0)
end

test_wasm_i64(test_normalize_id, (String,), "test_normalize_id", "+")

# ==========================================
# Test 3: Symbol construction
# ==========================================
println("\n=== Test 3: Symbol construction ===")

function test_symbol_construct(s::String)
    sym = Symbol(s)
    # Return 1 if symbol created successfully
    return sym === Symbol("+") ? Int64(1) : Int64(0)
end

test_wasm_i64(test_symbol_construct, (String,), "test_symbol_construct", "+")

# ==========================================
# Test 4: parse_julia_literal for K"Identifier" with "+"
# ==========================================
println("\n=== Test 4: parse_julia_literal for Identifier ===")

function test_pjl_identifier(s::String)
    txtbuf = unsafe_wrap(Vector{UInt8}, s)
    head = SyntaxHead(K"Identifier", UInt16(0))
    srcrange = UInt32(1):UInt32(length(s))
    result = parse_julia_literal(txtbuf, head, srcrange)
    # result should be Symbol("+")
    if result isa Symbol
        return Int64(1)
    else
        return Int64(0)
    end
end

test_wasm_i64(test_pjl_identifier, (String,), "test_pjl_identifier", "+")

# ==========================================
# Test 5: parse_julia_literal for K"Integer" with "1"
# ==========================================
println("\n=== Test 5: parse_julia_literal for Integer (known good) ===")

function test_pjl_integer(s::String)
    txtbuf = unsafe_wrap(Vector{UInt8}, s)
    head = SyntaxHead(K"Integer", UInt16(0))
    srcrange = UInt32(1):UInt32(length(s))
    result = parse_julia_literal(txtbuf, head, srcrange)
    if result isa Int64
        return result
    else
        return Int64(-999)
    end
end

test_wasm_i64(test_pjl_integer, (String,), "test_pjl_integer", "1")

# ==========================================
# Test 6: is_identifier and is_operator checks on Kind values
# ==========================================
println("\n=== Test 6: Kind predicate checks ===")

function test_kind_predicates()
    k_ident = K"Identifier"
    k_int = K"Integer"
    # Return bit flags: bit0=is_identifier(K"Identifier"), bit1=is_operator(K"Identifier"),
    # bit2=is_identifier(K"Integer"), bit3=is_operator(K"Integer")
    result = Int64(0)
    if is_identifier(k_ident)
        result |= 1
    end
    if is_operator(k_ident)
        result |= 2
    end
    if is_identifier(k_int)
        result |= 4
    end
    if is_operator(k_int)
        result |= 8
    end
    return result
end

test_wasm_i64(test_kind_predicates, (), "test_kind_predicates")

# ==========================================
# Test 7: SyntaxHead flag extraction
# ==========================================
println("\n=== Test 7: SyntaxHead flag extraction ===")

function test_syntaxhead_flags()
    sh1 = SyntaxHead(K"Identifier", UInt16(0))
    sh2 = SyntaxHead(K"Identifier", UInt16(1))  # TRIVIA_FLAG
    sh3 = SyntaxHead(K"Integer", UInt16(128))   # NON_TERMINAL_FLAG

    # Return bit flags for is_trivia checks
    result = Int64(0)
    if is_trivia(sh1)  # should be false
        result |= 1
    end
    if is_trivia(sh2)  # should be true
        result |= 2
    end
    if is_trivia(sh3)  # should be false
        result |= 4
    end
    return result  # Expected: 2 (only sh2 is trivia)
end

test_wasm_i64(test_syntaxhead_flags, (), "test_syntaxhead_flags")

# ==========================================
# Test 8: Full node_to_expr test - does it return non-nothing for leaf "1"?
# ==========================================
println("\n=== Test 8: node_to_expr for leaf integer ===")

function test_node_to_expr_leaf(s::String)
    # Parse the string, get the tree, and check if node_to_expr returns non-nothing
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps)
    source = JuliaSyntax.SourceFile(ps)
    txtbuf = JuliaSyntax.unsafe_textbuf(ps)
    cursor = RedTreeCursor(ps)

    # Get the first (only) child of toplevel
    itr = Iterators.reverse(cursor)
    r = iterate(itr)
    if r === nothing
        return Int64(-1)
    end
    (child, _) = r

    # For "1", child should be a leaf Integer
    if is_leaf(child)
        result = JuliaSyntax.node_to_expr(child, source, txtbuf)
        if result === nothing
            return Int64(0)
        elseif result isa Int64
            return result
        else
            return Int64(99)
        end
    else
        return Int64(-2)
    end
end

test_wasm_i64(test_node_to_expr_leaf, (String,), "test_node_to_expr_leaf", "1")

println("\nDone!")
