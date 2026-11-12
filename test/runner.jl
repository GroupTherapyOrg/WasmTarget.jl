# The differential runner, the third oracle's hands (AGENTS.md: native-vs-wasm execution; dev/AUDIT.md A46E1): it runs
# modules in node, the major .github/workflows/ci.yml names, and writes each call's RAW result in the judge's wire
# grammar (test/verdict.jl: `ret <kind> <bits> <ms>`, `exc <text>`, `err <text>` or `gap <text>`, a shape it cannot call
# or read). It judges nothing: the verdict is
# test/verdict.jl's, a judge file, which never loads this one (spec v16 X1). A keeper's file: what a keeper ports here is
# the node script and the marshalling of a new wasm shape into the wire's existing leaf kinds; a NEW leaf kind is the
# judge's edit (test/verdict.jl's LEAF_TYPES).
#
# Each call runs in ONE FRESH INSTANCE: a module's bytes are compiled once (WebAssembly.compile), and every call (every
# leaf a reader reads is a call) gets its own WebAssembly.Instance, as each native answer gets its own process; no state
# survives a call. The export is called from a wrapper module, compiled once per module and entry, that imports it (its
# exact type: the module's type section copied whole, so the import links under Wasm's canonical rec-group equality) and
# takes and returns integers alone: a float argument crosses JS as its integer bits and is reinterpreted inside wasm
# (f32.reinterpret_i32, f64.reinterpret_i64), a float result is reinterpreted to its integer bits before it leaves wasm
# (i32.reinterpret_f32, i64.reinterpret_f64), and a reference result is read as ref.is_null, so no value is ever
# converted by JS (whose ToWebAssemblyValue and ToJSValue quiet a signaling NaN: spec v16 X1, red 5).
#
#   julia test/runner.jl [--run-budget=s] [--node-start=s] [--part-chars=n] <out> <input>...
#                                           the run process (dev/climb/measure.py smoke; standalone test/smoke.jl and the
#                                           test suite's test/run_child.jl, as a child): each input's `module <label>
#                                           <key> <base64>` and `call <label> <j> <entry> <args...>` records (a call of
#                                           the label's j-th module), every call's raw line written to <out> in order
#   julia test/runner.jl --node             prints the node it runs (node_binary), or nothing
# Nothing else loads this file: no process that judges or writes a test's record runs a keeper's code (spec v17 Y5).
# Each call has a budget (test/verdict.jl's RUN_BUDGET): node is killed when a call gives no line within it (NODE_START
# more for a node's first), that call failing as a hang, named, and a new node runs the calls after it (spec v18 P3).
isdefined(Main, :WTVerdict) || Base.include(Main, joinpath(@__DIR__, "verdict.jl"))
module WTRunner

import Base64
using ..WTVerdict: RUN_BUDGET

const ROOT = dirname(@__DIR__)
const NODE_START = 30.0
# WasmTarget answers have_fma(Float64) true and rounds muladd and fma once, as native Julia does on an FMA host, and the
# differential reads Julia's math kernels bit for bit against native (test/smoke_corpus.jl's bit_exact_math). On a host
# without FMA, native Julia takes the kernels' other branches (have_fma in expm1), and every such case would read as
# WasmTarget's wrong answer: refused here, located, once (A84S6)
Core.Intrinsics.have_fma(Float64) || error("test/runner.jl: native Julia on this host has no fused multiply-add " *
    "(Core.Intrinsics.have_fma(Float64) is false), so its math kernels take branches WasmTarget's modules do not: " *
    "the differential runs on an FMA host only (A84S6)")

# the node of CI's major: THE node on PATH, when it is that major (spec v16 X4: one path). A build user's PATH starts with
# the copy the door pinned at launch (TOP/tools/bin/node, door.pin_node), so a `brew upgrade` mid-launch changes no
# measurement; CI's is setup-node's
# the lowest Node major whose V8 runs WT's modules: Node 22's (v22.23.3) traps "unreachable" entering any try_table
# with a reference result, with no WT code in it (test/src/runner.jl's "a try_table of a reference result" module,
# 12 lines, returns 7 on Node 26.11 and traps on Node 22; the corpus's wasm-opt'd modules of
# dart_switch/case_fallthrough, dart_switch/try_catch and dart_web_wasm/no_omit_error_details trapped so on
# f05b2fa8, 2026-11-01, wt3-cgstubs2). Node 24 is untried here, so the floor is the major that was run.
const NODE_MIN_MAJOR = 26
function node_binary()::Union{String,Nothing}
    local ci = read(joinpath(ROOT, ".github", "workflows", "ci.yml"), String)
    local m = match(r"node-version: *'?([0-9]+)", ci)
    m === nothing && return nothing
    local major = m[1]
    # no exception-handling module runs on an engine that traps it: a ci.yml naming an older Node is refused, located
    parse(Int, major) >= NODE_MIN_MAJOR || error(".github/workflows/ci.yml names Node $major, below test/runner.jl's " *
        "NODE_MIN_MAJOR $NODE_MIN_MAJOR: its V8 traps entering a try_table with a reference result " *
        "(test/src/runner.jl's \"a try_table of a reference result\" module)")
    local p = Sys.which("node")
    p === nothing && return nothing
    local v = try readchomp(`$p --version`) catch; "" end
    return startswith(v, "v$major.") ? p : nothing
end

# the script node runs: `m <id> <base64>` lines name the modules, each `c <id> <entry> <args...>` line is a call, and
# each call writes one raw line as it is known, so a hang shows where it stopped
const _JS = raw"""
'use strict';
const fs = require('fs');
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(l => l.length > 0);
// ---- a module's binary, read as far as a call needs: its type, import, function and export sections
class R {
  constructor(b, pos, end) { this.b = b; this.pos = pos; this.end = end; }
  byte() { if (this.pos >= this.end) throw new Error('the module ends inside a section'); return this.b[this.pos++]; }
  u32() { let r = 0, s = 0, x; do { x = this.byte(); r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); return r; }
  name() { const n = this.u32(); const s = this.b.subarray(this.pos, this.pos + n).toString('utf8'); this.pos += n; return s; }
}
const NUM = {0x7f: 'i32', 0x7e: 'i64', 0x7d: 'f32', 0x7c: 'f64'};
// a heap type: one byte of 0x40..0x7f is an abstract one (a negative s33), else a type index
const heap = (r) => { let x = r.b[r.pos]; if (x === 0x65) { r.pos++; x = r.b[r.pos]; } if (x >= 0x40 && x < 0x80) { r.pos++; return; } r.u32(); };
const valtype = (r) => {
  const x = r.byte();
  if (NUM[x] !== undefined) return {num: NUM[x]};
  if (x === 0x7b) return {vec: true};
  if (x === 0x63 || x === 0x64) { heap(r); return {ref: true}; }
  if (x >= 0x40 && x < 0x80) return {ref: true};
  throw new Error('a value type 0x' + x.toString(16) + ' the runner reads not');
};
const storage = (r) => { const x = r.b[r.pos]; if (x === 0x78 || x === 0x77) { r.pos++; return; } valtype(r); };
const comptype = (r) => {
  const k = r.byte();
  if (k === 0x60) { const ps = [], rs = []; for (let n = r.u32(); n > 0; n--) ps.push(valtype(r)); for (let n = r.u32(); n > 0; n--) rs.push(valtype(r)); return {func: true, params: ps, results: rs}; }
  if (k === 0x5f) { for (let n = r.u32(); n > 0; n--) { storage(r); r.byte(); } return {}; }
  if (k === 0x5e) { storage(r); r.byte(); return {}; }
  throw new Error('a composite type 0x' + k.toString(16) + ' the runner reads not');
};
const subtype = (r) => { const x = r.b[r.pos]; if (x === 0x50 || x === 0x4f) { r.pos++; for (let n = r.u32(); n > 0; n--) r.u32(); } return comptype(r); };
const limits = (r) => { const f = r.byte(); r.u32(); if (f & 1) r.u32(); };
function sections(b) {
  if (b.length < 8 || b.readUInt32LE(0) !== 0x6d736100) throw new Error('not a wasm module');
  const r = new R(b, 8, b.length), out = {};
  while (r.pos < b.length) { const id = r.byte(), n = r.u32(); if (id !== 0) out[id] = [r.pos, r.pos + n]; r.pos += n; }
  return out;
}
function types(b, [s, e]) {   // every type, in index order, and where the rec groups' bytes start
  const r = new R(b, s, e), n = r.u32(), start = r.pos, all = [];
  for (let i = 0; i < n; i++) { if (r.b[r.pos] === 0x4e) { r.pos++; for (let m = r.u32(); m > 0; m--) all.push(subtype(r)); } else all.push(subtype(r)); }
  return {count: n, start, end: e, all};
}
function importFuncs(b, [s, e]) {   // each imported function's type index, in order
  const r = new R(b, s, e), out = [];
  for (let n = r.u32(); n > 0; n--) {
    r.name(); r.name(); const k = r.byte();
    if (k === 0) out.push(r.u32()); else if (k === 1) { valtype(r); limits(r); } else if (k === 2) limits(r);
    else if (k === 3) { valtype(r); r.byte(); } else if (k === 4) { r.byte(); r.u32(); } else throw new Error('an import kind 0x' + k.toString(16));
  }
  return out;
}
const funcs = (b, [s, e]) => { const r = new R(b, s, e), out = []; for (let n = r.u32(); n > 0; n--) out.push(r.u32()); return out; };
const exportsOf = (b, [s, e]) => { const r = new R(b, s, e), out = []; for (let n = r.u32(); n > 0; n--) { const name = r.name(); out.push({name, kind: r.byte(), index: r.u32()}); } return out; };
const leb = (n) => { const out = []; do { let x = n % 128; n = Math.floor(n / 128); if (n > 0) x |= 0x80; out.push(x); } while (n > 0); return out; };
const str = (s) => { const b = Buffer.from(s, 'utf8'); return [...leb(b.length), ...b]; };
const sec = (id, body) => Buffer.concat([Buffer.from([id, ...leb(body.length)]), Buffer.from(body)]);
// the wrapper of export `entry` (`-`: the module's one exported function): `call`, taking each argument as an integer
// (an f32 as i32 bits, an f64 as i64 bits) and returning its result as one (a float's bits, a reference's ref.is_null)
function wrap(b, entry) {
  const s = sections(b);
  const fe = (s[7] ? exportsOf(b, s[7]) : []).filter(x => x.kind === 0);
  const name = entry === '-' ? (fe.length === 1 ? fe[0].name : null) : entry;
  const e = name === null ? undefined : fe.find(x => x.name === name);
  if (e === undefined) return {gap: 'no entry: the module exports the functions [' + fe.map(x => x.name).join(', ') + ']'};
  if (!s[1]) throw new Error('the module has no type section');
  const T = types(b, s[1]), imp = s[2] ? importFuncs(b, s[2]) : [], fn = s[3] ? funcs(b, s[3]) : [];
  const ti = e.index < imp.length ? imp[e.index] : fn[e.index - imp.length];
  const ft = T.all[ti];
  if (ft === undefined || !ft.func) throw new Error('its export ' + name + ' names no function type');
  const params = ft.params.map(p => p.num), res = ft.results.length === 0 ? 'void' : ft.results[0].num || (ft.results[0].ref ? 'ref' : undefined);
  if (params.some(p => p === undefined)) return {gap: 'the runner passes no argument of a reference or vector type (the export takes ' + ft.params.length + ' parameters)'};
  if (ft.results.length > 1 || res === undefined) return {gap: 'the runner reads no result of ' + (ft.results.length > 1 ? ft.results.length + ' values' : 'a vector type')};
  const ip = params.map(p => p === 'i32' || p === 'f32' ? 0x7f : 0x7e), ir = res === 'void' ? [] : res === 'i64' || res === 'f64' ? [0x7e] : [0x7f];
  const body = [0x00];
  params.forEach((p, i) => { body.push(0x20, ...leb(i)); if (p === 'f32') body.push(0xbe); if (p === 'f64') body.push(0xbf); });
  body.push(0x10, 0x00);
  if (res === 'f32') body.push(0xbc); if (res === 'f64') body.push(0xbd); if (res === 'ref') body.push(0xd1);
  body.push(0x0b);
  const typesec = Buffer.concat([Buffer.from(leb(T.count + 1)), b.subarray(T.start, T.end), Buffer.from([0x60, ...leb(ip.length), ...ip, ...leb(ir.length), ...ir])]);
  const w = Buffer.concat([Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]), sec(1, typesec),
    sec(2, [1, ...str('m'), ...str('f'), 0x00, ...leb(ti)]), sec(3, [1, ...leb(T.all.length)]),
    sec(7, [1, ...str('call'), 0x00, 1]), sec(10, [1, ...leb(body.length), ...body])]);
  return {wmod: new WebAssembly.Module(w), name, params, res};
}
// the standalone embedder's `dart` imports a module may take, dart's own test runner's
// (pkg/test_runner/lib/src/browser.dart:441 dartEmbedder, given as {dart: dartEmbedder} at :695): those
// the runtime's ports import, each as dart's runner writes it
const dartEmbedder = {
  // browser.dart:509-519
  stackTraceGetCurrent: () => new Error().stack,
  stackTraceToString: (trace) => {
    const stackString = trace.toString();
    const frames = stackString.split('\n');
    // Format of stack traces is:
    //   1. stackTraceGetCurrent (from this embedder object)
    //   2. module0.StackTrace.current <noInline>
    //   3. The callsite we care about.
    const drop = 1 + frames.findIndex((l) => l.indexOf('stackTraceGetCurrent') > 0);
    return frames.slice(drop).join('\n');
  },
};
const text = (e) => String(e && e.message || e).replace(/\s+/g, ' ');
const out = (l) => process.stdout.write(l + '\n');
const b64 = new Map(), mods = new Map();
(async () => {
  for (const line of lines) {
    const f = line.split(' ');
    if (f[0] === 'm') { b64.set(f[1], f[2]); continue; }
    const [, id, entry, ...args] = f;
    let m = mods.get(id), inst;
    try {
      if (m === undefined) {
        m = {bytes: Buffer.from(b64.get(id), 'base64'), wraps: new Map()};
        try { m.mod = await WebAssembly.compile(m.bytes); } catch (e) { m.err = 'the module does not compile: ' + text(e); }
        if (m.mod) {
          const missing = WebAssembly.Module.imports(m.mod).filter(i => !(i.module === 'dart' && i.kind === 'function' && i.name in dartEmbedder));
          if (missing.length > 0) m.gap = 'the module imports ' + missing.map(i => i.module + '.' + i.name).join(', ') + ', which the runner does not provide';
        }
        mods.set(id, m);
      }
      if (m.err) { out('err ' + m.err); continue; }
      if (m.gap) { out('gap ' + m.gap); continue; }
      let w = m.wraps.get(entry);
      if (w === undefined) { try { w = wrap(m.bytes, entry); } catch (e) { w = {err: 'the runner reads no module whose sections it cannot read: ' + text(e)}; } m.wraps.set(entry, w); }
      if (w.err) { out('err ' + w.err); continue; }
      if (w.gap) { out('gap ' + w.gap); continue; }
      const kinds = args.map(a => a.split(':')[0]);
      if (kinds.join(',') !== w.params.join(',')) { out('err the call passes (' + kinds.join(', ') + ') to an export of (' + w.params.join(', ') + ')'); continue; }
      const vals = args.map(a => { const [t, v] = a.split(':'); return t === 'i32' || t === 'f32' ? Number(BigInt.asIntN(32, BigInt('0x' + v))) : BigInt.asIntN(64, BigInt('0x' + v)); });
      inst = new WebAssembly.Instance(m.mod, {dart: dartEmbedder});   // a fresh instance a call: no state survives it
      const call = new WebAssembly.Instance(w.wmod, {m: {f: inst.exports[w.name]}}).exports.call;
      const t0 = performance.now();
      const r = call(...vals);
      const ms = (performance.now() - t0).toFixed(1);
      if (w.res === 'void') out('ret void - ' + ms);
      else if (w.res === 'ref') out('ret ' + (r === 1 ? 'null' : 'ref') + ' - ' + ms);
      else if (w.res === 'i32' || w.res === 'f32') out('ret ' + w.res + ' ' + (r >>> 0).toString(16).padStart(8, '0') + ' ' + ms);
      else out('ret ' + w.res + ' ' + BigInt.asUintN(64, r).toString(16).padStart(16, '0') + ' ' + ms);
    } catch (e) {
      // a wasm exception (the module's throw) apart from a trap (unreachable, an integer divided by zero); a wasm
      // exception counts only under the module's one exported tag, its exception tag (A61E1)
      if (e instanceof WebAssembly.Exception && inst !== undefined) {
        const tags = WebAssembly.Module.exports(m.mod).filter(x => x.kind === 'tag');
        if (tags.length !== 1) out('err a wasm exception, and the module exports ' + tags.length + ' tags, not its one exception tag to match it against');
        else if (!e.is(inst.exports[tags[0].name])) out('err a wasm exception under another tag than the module\'s exported ' + tags[0].name);
        else out('exc ' + text(e));
      } else out((e instanceof WebAssembly.RuntimeError ? 'err trap: ' : 'err ') + text(e));
    }
  }
})();
"""

# a part of the calls one node reads, in characters of its input: well under node's 0x1fffffe8 a string
const RUN_PART_CHARS = 200_000_000

"""
    run_lines(calls; run_budget, node_start, part_chars) -> Vector{String}

Each call `(module base64, entry, wire arguments)` run in node, its raw line (test/verdict.jl's wire) in order. The calls
go in parts, each read by a node of its own (node reads its input as one string, at most 0x1fffffe8 characters, and the
whole corpus's base64 modules passed that on 2026-11-09), each module once a part. The budget is a call's (spec v18 P3,
red round 15 2): node is killed when no line comes for `run_budget` seconds (`node_start` more for a node's first
line), the call in flight answers `err … node killed: a hang`, and a new node runs the part's later calls, so one
hanging module costs its own call alone, never a fixture or a later case.
"""
function run_lines(calls::AbstractVector; run_budget::Float64 = RUN_BUDGET, node_start::Float64 = NODE_START,
                   part_chars::Int = RUN_PART_CHARS)::Vector{String}
    isempty(calls) && return String[]
    local node = node_binary()
    node === nothing && return fill("err no node of the major .github/workflows/ci.yml names", length(calls))
    local parts, lo, size, seen = UnitRange{Int}[], 1, 0, Set{String}()
    for (k, (m, entry, args)) in enumerate(calls)
        local cost = sizeof(entry) + sum(sizeof, args; init = 0) + 16
        if k > lo && size + cost + (m in seen ? 0 : sizeof(m) + 16) > part_chars
            push!(parts, lo:k-1); lo, size = k, 0; empty!(seen)
        end
        size += cost + (m in seen ? 0 : sizeof(m) + 16); push!(seen, m)
    end
    push!(parts, lo:length(calls))
    local dir = mktempdir()
    local js = joinpath(dir, "run.js")
    write(js, _JS)
    local raw = Vector{String}(undef, length(calls))
    for part in parts
        local todo = collect(part)
        while !isempty(todo)   # one node for the calls left; a kill or a crash ends its call alone
            local inp = joinpath(dir, "calls.txt")
            local ids = Dict{String,Int}()
            open(inp, "w") do io
                for k in todo
                    local m = calls[k][1]
                    haskey(ids, m) || (ids[m] = length(ids); println(io, "m ", ids[m], " ", m))
                end
                for k in todo
                    local m, entry, args = calls[k]
                    println(io, join(["c", ids[m], isempty(entry) ? "-" : entry, args...], ' '))
                end
            end
            local out, err = Pipe(), IOBuffer()
            local proc = run(pipeline(`$node $js $inp`; stdout = out, stderr = err); wait = false)
            close(out.in)
            local got, t_last = String[], Ref(time())
            local reader = @async for l in eachline(out)
                push!(got, l); t_last[] = time()
            end
            local killed, limit = false, run_budget + node_start
            while process_running(proc)
                sleep(0.02)
                limit = run_budget + (isempty(got) ? node_start : 0.0)
                if time() - t_last[] > limit
                    killed = true; kill(proc); break
                end
            end
            try wait(proc) catch end
            wait(reader)
            local n = min(length(got), length(todo))
            for j in 1:n
                raw[todo[j]] = got[j]
            end
            n == length(todo) && break
            raw[todo[n+1]] = killed ? "err no answer within $(round(limit; digits = 2)) s, node killed: a hang or a blow-up" :
                "err node gave no answer: " * replace(strip(String(take!(err))), r"\s+" => " ")
            todo = todo[n+2:end]
        end
    end
    rm(dir; recursive = true, force = true)
    return raw
end

"""
    run_files(inputs) -> Vector{String}

The run process's calls: each input's `call <label> <j> <entry> <args...>` records, in order, each of the j-th `module
<label> <key> <base64>` record of its label before it in the same input; run (run_lines), one raw line a call. A call
naming a module its input does not hold is its own `err` line, located."""
function run_files(inputs::AbstractVector{<:AbstractString}; kw...)::Vector{String}
    local calls, early = Tuple{String,String,Vector{String}}[], Dict{Int,String}()
    local n = 0
    for p in inputs
        local mods = Dict{String,Vector{String}}()
        for ln in eachline(p)
            local f = split(ln, '\t')
            if f[1] == "module" && length(f) >= 4
                push!(get!(mods, String(f[2]), String[]), String(f[4]))
            elseif f[1] == "call" && length(f) >= 4
                n += 1
                local ms, j = get(mods, String(f[2]), String[]), tryparse(Int, f[3])
                if j === nothing || !(0 <= j < length(ms))
                    early[n] = "err the call names module $(f[3]) of $(f[2]), which no module record before it holds"
                else
                    push!(calls, (ms[j+1], String(f[4]), String.(f[5:end])))
                end
            end
        end
    end
    local ran = run_lines(calls; kw...)
    local out, k = String[], 0
    for i in 1:n
        haskey(early, i) ? push!(out, early[i]) : push!(out, ran[k += 1])
    end
    return out
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && let opts = Dict{String,String}(), args = String[]
    for a in ARGS   # `--name=value` options, then the out file and the inputs
        local m = match(r"^--(run-budget|node-start|part-chars)=(.+)$", a)
        if m !== nothing
            opts[m[1]] = m[2]
        elseif a == "--node"
            print(something(WTRunner.node_binary(), "")); exit(0)
        else
            push!(args, a)
        end
    end
    local kw = (; run_budget = parse(Float64, get(opts, "run-budget", string(WTVerdict.RUN_BUDGET))),
                node_start = parse(Float64, get(opts, "node-start", string(WTRunner.NODE_START))),
                part_chars = parse(Int, get(opts, "part-chars", string(WTRunner.RUN_PART_CHARS))))
    local lines = WTRunner.run_files(args[2:end]; kw...)
    write(args[1], join((l * "\n" for l in lines)))
end
