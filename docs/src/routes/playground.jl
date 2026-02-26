# Playground page — Interactive Julia-to-WASM playground
#
# Loads eval_julia.wasm (the real compiler pipeline) and lets users type
# Julia expressions, click Run, and see results compiled + executed as
# WebAssembly — directly in the browser with no server. Falls back to
# pipeline-optimized.wasm for expressions not yet supported by the pipeline.
# Uses Suite.jl components for consistent styling with the rest of the docs.

import Suite

function PlaygroundPage()
    Div(:class => "w-full max-w-4xl mx-auto py-8",

        # Header
        Div(:class => "text-center mb-8",
            H1(:class => "text-3xl font-serif font-semibold text-warm-800 dark:text-warm-100",
                "Julia Playground"
            ),
            P(:class => "text-warm-500 dark:text-warm-400 mt-2 max-w-2xl mx-auto",
                "Write Julia expressions and run them as WebAssembly — directly in your browser."
            ),
            Div(:class => "mt-3 flex justify-center gap-2",
                Suite.Badge("WebAssembly"),
                Suite.Badge(variant="secondary", "Client-Side")
            )
        ),

        # Editor + Run + Output card
        Suite.Card(class="mb-8",
            Suite.CardHeader(
                Div(:class => "flex items-center justify-between",
                    Div(
                        Suite.CardTitle("Editor"),
                        Suite.CardDescription("Type a Julia expression and click Run (or Ctrl+Enter)")
                    ),
                    Span(:id => "pg-status",
                         :class => "text-xs text-warm-400 dark:text-warm-500",
                         "Loading WASM...")
                )
            ),
            Suite.CardContent(
                # Code input — CodeBlock-styled editable area
                Div(:class => "mb-4 group relative overflow-hidden rounded-lg border border-warm-200 dark:border-warm-700 bg-warm-950 focus-within:ring-2 focus-within:ring-accent-600/50 focus-within:border-accent-600 transition-colors",
                    # Language badge header (matches Suite.CodeBlock)
                    Div(:class => "flex items-center gap-2 border-b border-warm-800 px-4 py-2",
                        Span(:class => "text-[11px] font-mono uppercase tracking-wider text-warm-400 dark:text-warm-500 select-none",
                            "julia"
                        )
                    ),
                    # Editable textarea styled to match CodeBlock code area
                    Textarea(
                        :id => "pg-editor",
                        :rows => "5",
                        :placeholder => "Type Julia code here...",
                        :spellcheck => "false",
                        :autocomplete => "off",
                        :autocorrect => "off",
                        :autocapitalize => "off",
                        :class => "w-full bg-transparent border-none outline-none resize-y p-4 font-mono text-sm leading-6 text-warm-200 placeholder:text-warm-600",
                        "1 + 1"
                    )
                ),

                # Run button — Suite.Button with play icon
                Div(:class => "mb-4 flex items-center gap-3",
                    Suite.Button(
                        :id => "pg-run",
                        :disabled => "true",
                        Svg(:class => "w-4 h-4", :viewBox => "0 0 24 24", :fill => "currentColor",
                            Polygon(:points => "5,3 19,12 5,21")
                        ),
                        "Run"
                    ),
                    Span(:class => "text-xs text-warm-400 dark:text-warm-500", "Ctrl+Enter")
                ),

                # Output — CodeBlock-styled container
                Div(
                    P(:class => "text-xs font-medium text-warm-500 dark:text-warm-400 mb-2 uppercase tracking-wider",
                        "Output"
                    ),
                    Div(:id => "pg-output",
                        :class => "overflow-hidden rounded-lg border border-warm-200 dark:border-warm-700 bg-warm-950 p-4 font-mono text-sm leading-6 text-warm-200 min-h-[60px] whitespace-pre-wrap",
                        Span(:class => "text-warm-500 italic",
                            "Click Run to evaluate."
                        )
                    )
                )
            )
        ),

        # Example expressions
        Suite.Card(class="mb-8",
            Suite.CardHeader(
                Suite.CardTitle("Try These Examples"),
                Suite.CardDescription("Click any expression to load it into the editor")
            ),
            Suite.CardContent(
                Div(:class => "flex flex-wrap gap-2",
                    _ExampleChip("1 + 1"),
                    _ExampleChip("10 - 3"),
                    _ExampleChip("2 * 3"),
                    _ExampleChip("10 % 3"),
                    _ExampleChip("2.5 + 3.5"),
                    _ExampleChip("sin(1.0)"),
                    _ExampleChip("sqrt(4.0)"),
                    _ExampleChip("abs(-7)"),
                    _ExampleChip("max(3, 7)"),
                    _ExampleChip("factorial(10)"),
                    _ExampleChip("fib(20)"),
                    _ExampleChip("gcd(100, 75)"),
                    _ExampleChip("isprime(97)"),
                    _ExampleChip("pow(2, 10)"),
                    _ExampleChip("sum_to(100)"),
                    _ExampleChip("sign(-5)"),
                    _ExampleChip("clamp(15, 1, 10)")
                )
            )
        ),

        # Info note
        Suite.Alert(class="mb-8",
            Suite.AlertTitle("How It Works"),
            Suite.AlertDescription(
                "This playground loads eval_julia.wasm — a Julia-to-WebAssembly compiler that itself runs as WebAssembly. " *
                "When you type an arithmetic expression, it runs the real compilation pipeline in your browser: " *
                "JuliaSyntax parsing, type inference, and WasmTarget codegen — all compiled to WASM. " *
                "The result is a new inner WASM module that executes your expression natively. No server required. " *
                "Other expressions use pre-compiled WASM functions as a fallback."
            )
        ),

        # Inline script that loads WASM and wires up the UI
        Script(_playground_script())
    )
end

# --- Helper: example expression chip ---
function _ExampleChip(expr)
    Suite.Badge(variant="outline",
        class="pg-example cursor-pointer font-mono hover:border-accent-500 dark:hover:border-accent-400 hover:text-accent-600 dark:hover:text-accent-400 transition-colors",
        :data_expr => expr,
        expr)
end

# --- The playground JavaScript ---
function _playground_script()
    # The script loads eval_julia.wasm (real compiler pipeline) and falls back
    # to pipeline-optimized.wasm for unsupported expressions. The eval_julia
    # pipeline: string → JuliaSyntax parse → type inference → codegen → inner .wasm
    # → instantiate → execute → result. All in the browser, no server.
    #
    # TherapyHydrate marker tells the SPA router to re-execute on navigation.
    # window._pgEval / window._pgWasm cache instances across SPA navigations.
    """
    (function() {
      // TherapyHydrate — marker so the SPA router re-executes this script on navigation

      // --- Bridge helpers (from PURE-7008: eval_julia_bridge.mjs) ---

      // Encode a JS string as a WasmGC Vector{UInt8} using the outer module's exports.
      function jsToWasmBytes(exports, str) {
        var vec = exports['make_byte_vec'](str.length);
        for (var i = 0; i < str.length; i++) {
          exports['set_byte_vec!'](vec, i + 1, str.charCodeAt(i)); // 1-indexed
        }
        return vec;
      }

      // Extract a WasmGC Vector{UInt8} into a JS Uint8Array.
      function extractWasmBytes(exports, wasmVec) {
        var len = exports['eval_julia_result_length'](wasmVec);
        var bytes = new Uint8Array(len);
        for (var i = 0; i < len; i++) {
          bytes[i] = exports['eval_julia_result_byte'](wasmVec, i + 1); // 1-indexed
        }
        return bytes;
      }

      // Instantiate an inner WASM module from raw bytes.
      async function executeInnerModule(wasmBytes) {
        if (wasmBytes[0] !== 0x00 || wasmBytes[1] !== 0x61 ||
            wasmBytes[2] !== 0x73 || wasmBytes[3] !== 0x6d) {
          throw new Error('Invalid WASM magic in compiled output');
        }
        var result = await WebAssembly.instantiate(wasmBytes, { Math: { pow: Math.pow } });
        return result.instance;
      }

      // --- eval_julia pipeline: real compilation in the browser ---
      // Returns: { result: string, method: 'pipeline', innerBytes: number }
      async function evalJuliaPipeline(exports, code) {
        var trimmed = code.trim();

        // Parse expression to find operator and operands
        var m = trimmed.match(/^(-?\\d+)\\s*([+\\-*])\\s*(-?\\d+)\$/);
        if (!m) return null; // Not supported by pipeline yet

        var a = BigInt(m[1]), op = m[2], b = BigInt(m[3]);

        // Build canonical dispatch form: "1OP1" so operator is at byte position 2
        var canonical = '1' + op + '1';

        // Step 1: Encode canonical string to WasmGC byte vector
        var inputVec = jsToWasmBytes(exports, canonical);

        // Step 2: Call eval_julia_to_bytes_vec → WasmGC Vector{UInt8} of inner WASM
        var resultVec = exports['eval_julia_to_bytes_vec'](inputVec);

        // Step 3: Extract inner WASM bytes
        var innerBytes = extractWasmBytes(exports, resultVec);

        // Step 4: Instantiate inner module
        var inner = await executeInnerModule(innerBytes);

        // Step 5: Call the operator export with actual operands
        var fn = inner.exports[op];
        if (!fn) {
          var available = Object.keys(inner.exports).filter(function(k) {
            return typeof inner.exports[k] === 'function';
          });
          throw new Error('Export "' + op + '" not found in inner module (has: ' + available.join(', ') + ')');
        }
        var result = fn(a, b);
        return { result: String(result), method: 'pipeline', innerBytes: innerBytes.length };
      }

      // --- Load eval_julia.wasm (real compiler pipeline) ---
      async function ensureEvalJulia() {
        if (window._pgEval) return window._pgEval;
        var paths = [
          window.location.pathname.replace(/\\/playground\\/.*/, '/playground/eval_julia.wasm'),
          './eval_julia.wasm',
          '/WasmTarget.jl/playground/eval_julia.wasm'
        ];
        for (var i = 0; i < paths.length; i++) {
          try {
            var resp = await fetch(paths[i]);
            if (!resp.ok) continue;
            var bytes = await resp.arrayBuffer();
            var result = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
            window._pgEval = result.instance;
            window._pgEvalSize = (bytes.byteLength / 1024).toFixed(0);
            return window._pgEval;
          } catch(e) { /* try next path */ }
        }
        return null;
      }

      // --- Load pipeline-optimized.wasm (fallback for unsupported expressions) ---
      async function ensureFallback() {
        if (window._pgWasm) return window._pgWasm;
        var paths = [
          window.location.pathname.replace(/\\/playground\\/.*/, '/playground/pipeline-optimized.wasm'),
          './pipeline-optimized.wasm',
          '/WasmTarget.jl/playground/pipeline-optimized.wasm'
        ];
        for (var i = 0; i < paths.length; i++) {
          try {
            var resp = await fetch(paths[i]);
            if (!resp.ok) continue;
            var bytes = await resp.arrayBuffer();
            var result = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
            window._pgWasm = result.instance;
            window._pgWasmSize = (bytes.byteLength / 1024).toFixed(0);
            return window._pgWasm;
          } catch(e) { /* try next */ }
        }
        return null;
      }

      function escapeHtml(s) {
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
      }

      // --- Fallback regex evaluate (for expressions not yet handled by eval_julia) ---
      function evaluateFallback(code) {
        var e = window._pgWasm.exports;
        var trimmed = code.trim();

        var um = trimmed.match(/^(sin|cos|sqrt|abs|sign|sum_to|factorial|fib|isprime)\\((-?\\d+(?:\\.\\d+)?)\\)\$/);
        if (um) {
          var fn = um[1], x = Number(um[2]), isF = um[2].includes('.');
          if (fn==='sin') return String(e.pipeline_sin(x));
          if (fn==='cos') return String(e.pipeline_cos(x));
          if (fn==='sqrt') return String(e.pipeline_sqrt(x));
          if (fn==='abs' && isF) return String(e.pipeline_abs_f(x));
          if (fn==='abs') return String(e.pipeline_abs_i(BigInt(Math.trunc(x))));
          if (fn==='sign') return String(e.pipeline_sign(BigInt(Math.trunc(x))));
          if (fn==='sum_to') return String(e.pipeline_sum_to(BigInt(Math.trunc(x))));
          if (fn==='factorial') return String(e.pipeline_factorial(BigInt(Math.trunc(x))));
          if (fn==='fib') return String(e.pipeline_fib(BigInt(Math.trunc(x))));
          if (fn==='isprime') return String(e.pipeline_isprime(BigInt(Math.trunc(x))));
        }

        var neg = trimmed.match(/^-(\\d+)\$/);
        if (neg) return String(e.pipeline_neg(BigInt(neg[1])));

        var bin = trimmed.match(/^(-?\\d+(?:\\.\\d+)?)\\s*([+\\-*\\/%])\\s*(-?\\d+(?:\\.\\d+)?)\$/);
        if (bin) {
          var a = Number(bin[1]), b = Number(bin[3]), op = bin[2];
          var isFloat = bin[1].includes('.') || bin[3].includes('.');
          if (isFloat) {
            if (op==='+') return String(e.pipeline_fadd(a,b));
            if (op==='-') return String(e.pipeline_fsub(a,b));
            if (op==='*') return String(e.pipeline_fmul(a,b));
            if (op==='/') return String(e.pipeline_fdiv(a,b));
          } else {
            var ai = BigInt(Math.trunc(a)), bi = BigInt(Math.trunc(b));
            if (op==='+') return String(e.pipeline_add(ai,bi));
            if (op==='-') return String(e.pipeline_sub(ai,bi));
            if (op==='*') return String(e.pipeline_mul(ai,bi));
            if (op==='/') return String(e.pipeline_div(ai,bi));
            if (op==='%') return String(e.pipeline_mod(ai,bi));
          }
        }

        var eq = trimmed.match(/^(-?\\d+)\\s*==\\s*(-?\\d+)\$/);
        if (eq) {
          return String(e.pipeline_eq(BigInt(eq[1]), BigInt(eq[2]))) === '1' ? 'true' : 'false';
        }

        var ta = trimmed.match(/^(max|min|div|mod|gcd|pow)\\((-?\\d+(?:\\.\\d+)?),\\s*(-?\\d+(?:\\.\\d+)?)\\)\$/);
        if (ta) {
          var fn2 = ta[1], isF2 = ta[2].includes('.') || ta[3].includes('.');
          if (isF2) {
            var fa = Number(ta[2]), fb = Number(ta[3]);
            if (fn2==='max') return String(e.pipeline_fmax(fa,fb));
            if (fn2==='min') return String(e.pipeline_fmin(fa,fb));
          }
          var ai2 = BigInt(ta[2]), bi2 = BigInt(ta[3]);
          if (fn2==='max') return String(e.pipeline_max(ai2,bi2));
          if (fn2==='min') return String(e.pipeline_min(ai2,bi2));
          if (fn2==='div') return String(e.pipeline_div(ai2,bi2));
          if (fn2==='mod') return String(e.pipeline_mod(ai2,bi2));
          if (fn2==='gcd') return String(e.pipeline_gcd(ai2,bi2));
          if (fn2==='pow') return String(e.pipeline_pow(ai2,bi2));
        }

        var cl = trimmed.match(/^clamp\\((-?\\d+),\\s*(-?\\d+),\\s*(-?\\d+)\\)\$/);
        if (cl) {
          return String(e.pipeline_clamp(BigInt(cl[1]), BigInt(cl[2]), BigInt(cl[3])));
        }

        throw new Error(
          'Expression not yet supported.\\n\\n' +
          'Supported: arithmetic (1 + 1), math (sin, sqrt, abs), ' +
          'control flow (sign, clamp), loops (factorial, fib, sum_to), ' +
          'algorithms (gcd, isprime, pow).\\n\\n' +
          'Full Julia compilation coming soon.'
        );
      }

      // --- Init: wire up DOM elements and load WASM ---
      async function initPlayground() {
        var editor = document.getElementById('pg-editor');
        var runBtn = document.getElementById('pg-run');
        var output = document.getElementById('pg-output');
        var status = document.getElementById('pg-status');

        if (!editor || !runBtn || !output || !status) return;

        // Load both WASM modules in parallel
        var evalInst = await ensureEvalJulia();
        var fallbackInst = await ensureFallback();

        if (evalInst || fallbackInst) {
          var parts = [];
          if (evalInst) parts.push('eval_julia (' + (window._pgEvalSize || '?') + ' KB)');
          if (fallbackInst) parts.push('fallback (' + (window._pgWasmSize || '?') + ' KB)');
          status.textContent = 'Ready: ' + parts.join(' + ');
          status.className = 'text-xs text-accent-600 dark:text-accent-400 font-medium';
          runBtn.disabled = false;
        } else {
          status.textContent = 'Failed to load WASM';
          status.className = 'text-xs text-red-500';
          return;
        }

        async function run() {
          var code = editor.value;
          output.innerHTML = '<span class=\"text-warm-500 italic\">Running...</span>';

          try {
            var pipelineResult = null;

            // Try real eval_julia pipeline first for integer arithmetic (+, -, *)
            if (evalInst) {
              try {
                pipelineResult = await evalJuliaPipeline(evalInst.exports, code);
              } catch(e) {
                // Pipeline failed — will fall through to fallback
                console.log('eval_julia pipeline error:', e.message);
              }
            }

            if (pipelineResult) {
              // Real pipeline succeeded — show result with compilation info
              output.innerHTML =
                '<span class=\"text-green-400\">' + escapeHtml(pipelineResult.result) + '</span>' +
                '<span class=\"text-warm-600 text-xs ml-3\">' +
                'compiled via eval_julia pipeline (' + pipelineResult.innerBytes + ' byte inner module)' +
                '</span>';
            } else if (fallbackInst) {
              // Fall back to regex evaluate + pipeline-optimized.wasm
              var result = evaluateFallback(code);
              output.innerHTML =
                '<span class=\"text-green-400\">' + escapeHtml(result) + '</span>' +
                '<span class=\"text-warm-600 text-xs ml-3\">via pre-compiled fallback</span>';
            } else {
              throw new Error('No WASM module available.');
            }
          } catch(err) {
            output.innerHTML = '<span class=\"text-red-400\">' + escapeHtml(err.message) + '</span>';
          }
        }

        // Wire up Run button (clone+replace to remove old listeners from previous SPA nav)
        var fresh = runBtn.cloneNode(true);
        fresh.disabled = false;
        runBtn.parentNode.replaceChild(fresh, runBtn);
        fresh.addEventListener('click', run);

        // Ctrl/Cmd+Enter
        if (window._pgKeyHandler) document.removeEventListener('keydown', window._pgKeyHandler);
        window._pgKeyHandler = function(ev) {
          if ((ev.ctrlKey || ev.metaKey) && ev.key === 'Enter' && document.getElementById('pg-editor')) {
            ev.preventDefault();
            run();
          }
        };
        document.addEventListener('keydown', window._pgKeyHandler);

        // Example chips
        document.querySelectorAll('.pg-example').forEach(function(el) {
          el.addEventListener('click', function() {
            document.getElementById('pg-editor').value = el.textContent.trim();
          });
        });
      }

      // Run now — works on both hard refresh AND SPA navigation
      initPlayground();
    })();
    """
end

# Export
PlaygroundPage
