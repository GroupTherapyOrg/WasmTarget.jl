# Playground page — Interactive Julia-to-WASM playground
#
# A standard docs route that loads pipeline-optimized.wasm and lets users
# type Julia expressions, click Run, and see results. Uses Suite.jl
# components for consistent styling with the rest of the docs.

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
                        Suite.CardDescription("Type a Julia expression and click Run (or press Ctrl+Enter)")
                    ),
                    Span(:id => "pg-status",
                         :class => "text-xs text-warm-400 dark:text-warm-500",
                         "Loading WASM...")
                )
            ),
            Suite.CardContent(
                # Code input
                Div(:class => "mb-4",
                    Textarea(
                        :id => "pg-editor",
                        :class => "w-full min-h-[120px] p-4 font-mono text-sm bg-warm-50 dark:bg-warm-900 border border-warm-200 dark:border-warm-700 rounded-lg text-warm-800 dark:text-warm-100 focus:outline-none focus:ring-2 focus:ring-accent-500 focus:border-accent-500 resize-y",
                        :placeholder => "Type Julia code here...",
                        :spellcheck => "false",
                        "1 + 1"
                    )
                ),

                # Run button
                Div(:class => "mb-4",
                    Button(
                        :id => "pg-run",
                        :class => "inline-flex items-center gap-2 px-5 py-2 bg-accent-600 hover:bg-accent-700 text-white font-semibold rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed",
                        :disabled => "true",
                        Svg(:class => "w-4 h-4", :viewBox => "0 0 24 24", :fill => "currentColor",
                            Polygon(:points => "5,3 19,12 5,21")
                        ),
                        "Run"
                    )
                ),

                # Output
                Div(
                    P(:class => "text-xs font-medium text-warm-500 dark:text-warm-400 mb-2 uppercase tracking-wider",
                        "Output"
                    ),
                    Div(:id => "pg-output",
                        :class => "p-4 font-mono text-sm bg-warm-50 dark:bg-warm-900 border border-warm-200 dark:border-warm-700 rounded-lg min-h-[60px] whitespace-pre-wrap",
                        Span(:class => "text-warm-400 dark:text-warm-500 italic",
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
                "This playground loads a 216 KB WebAssembly module (pipeline-optimized.wasm) compiled from Julia by WasmTarget.jl. " *
                "Your expressions are matched to pre-compiled WASM functions that execute natively in the browser — no server required. " *
                "Full arbitrary code compilation is coming in a future update."
            )
        ),

        # Inline script that loads WASM and wires up the UI
        Script(_playground_script())
    )
end

# --- Helper: example expression chip ---
function _ExampleChip(expr)
    Code(:class => "pg-example cursor-pointer px-2 py-1 text-xs font-mono bg-warm-100 dark:bg-warm-800 border border-warm-200 dark:border-warm-700 rounded hover:border-accent-500 dark:hover:border-accent-400 transition-colors text-warm-700 dark:text-warm-300",
         :data_expr => expr,
         expr)
end

# --- The playground JavaScript ---
function _playground_script()
    # Use the base_path for WASM URL since we're on GitHub Pages at /WasmTarget.jl/
    """
    (function() {
      var wasmInstance = null;
      var editor = document.getElementById('pg-editor');
      var runBtn = document.getElementById('pg-run');
      var output = document.getElementById('pg-output');
      var status = document.getElementById('pg-status');

      // Load WASM
      var wasmPaths = [
        window.location.pathname.replace(/\\/playground\\/.*/, '/playground/pipeline-optimized.wasm'),
        './pipeline-optimized.wasm',
        '/WasmTarget.jl/playground/pipeline-optimized.wasm'
      ];

      async function loadWasm() {
        for (var i = 0; i < wasmPaths.length; i++) {
          try {
            var resp = await fetch(wasmPaths[i]);
            if (!resp.ok) continue;
            var bytes = await resp.arrayBuffer();
            var importObject = { Math: { pow: Math.pow } };
            var result = await WebAssembly.instantiate(bytes, importObject);
            wasmInstance = result.instance;
            var size = (bytes.byteLength / 1024).toFixed(0);
            status.textContent = 'Ready (' + size + ' KB)';
            status.className = 'text-xs text-green-600 dark:text-green-400';
            runBtn.disabled = false;
            return;
          } catch(e) { /* try next */ }
        }
        status.textContent = 'Failed to load WASM';
        status.className = 'text-xs text-red-500';
      }

      function escapeHtml(s) {
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
      }

      function evaluate(code) {
        var e = wasmInstance.exports;
        var trimmed = code.trim();

        // Unary math: func(number)
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

        // Negation: -number
        var neg = trimmed.match(/^-(\\d+)\$/);
        if (neg) return String(e.pipeline_neg(BigInt(neg[1])));

        // Binary: number op number
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

        // Comparison: number == number
        var eq = trimmed.match(/^(-?\\d+)\\s*==\\s*(-?\\d+)\$/);
        if (eq) {
          return String(e.pipeline_eq(BigInt(eq[1]), BigInt(eq[2]))) === '1' ? 'true' : 'false';
        }

        // Two-arg: func(a, b)
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

        // Three-arg: clamp(x, lo, hi)
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

      function run() {
        var code = editor.value;
        try {
          var result = evaluate(code);
          output.innerHTML = '<span class=\"text-warm-800 dark:text-warm-100\">' + escapeHtml(result) + '</span>';
        } catch(err) {
          output.innerHTML = '<span class=\"text-red-500\">' + escapeHtml(err.message) + '</span>';
        }
      }

      runBtn.addEventListener('click', run);

      document.addEventListener('keydown', function(ev) {
        if ((ev.ctrlKey || ev.metaKey) && ev.key === 'Enter' && !runBtn.disabled) {
          ev.preventDefault();
          run();
        }
      });

      // Example chips
      document.querySelectorAll('.pg-example').forEach(function(el) {
        el.addEventListener('click', function() {
          editor.value = el.getAttribute('data-expr');
        });
      });

      loadWasm();
    })();
    """
end

# Export
PlaygroundPage
