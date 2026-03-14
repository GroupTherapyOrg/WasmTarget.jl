# Playground — Live Julia-to-WASM compiler
#
# Uses a plain textarea editor (no CodeMirror dependency headaches).
# Compiles code via POST /compile endpoint, executes in Web Worker.
# Requires: julia +1.12 --project=. scripts/serve.jl

function PlaygroundPage()
    Div(:class => "-mx-4 sm:-mx-6 lg:-mx-8 -my-8 flex flex-col",
        :style => "height: calc(100vh - 64px);",

        Div(:class => "flex flex-col flex-1 overflow-hidden",

            # Toolbar
            Div(:class => "flex items-center justify-between px-4 py-2 border-b border-warm-200 dark:border-warm-800 bg-warm-100 dark:bg-warm-900",
                Div(:class => "flex items-center gap-3",
                    Span(:class => "text-sm font-medium text-warm-700 dark:text-warm-300", "Julia Playground"),
                    Span(:id => "pg-status", :class => "text-xs text-warm-500 dark:text-warm-400"),
                ),
                Div(:class => "flex items-center gap-2",
                    Button(:id => "pg-run",
                        :class => "px-4 py-1.5 text-sm font-semibold rounded-md bg-accent-600 hover:bg-accent-700 text-white dark:bg-accent-500 dark:hover:bg-accent-400 dark:text-warm-950 transition-colors disabled:opacity-50 disabled:cursor-wait",
                        "Run (Ctrl+Enter)"
                    ),
                )
            ),

            # Editor pane — plain textarea
            Textarea(:id => "pg-editor",
                :class => "flex-1 w-full px-4 py-3 font-mono text-sm bg-warm-950 text-warm-200 border-b border-warm-800 resize-none focus:outline-none",
                :style => "min-height: 200px; tab-size: 4;",
                :spellcheck => "false",
                :autocorrect => "off",
                :autocapitalize => "off",
                raw"""# Julia Playground — powered by WasmTarget.jl
# Your code is compiled to WebAssembly and executed in the browser.

println("Hello from Julia!")
println("1 + 1 = ", 1 + 1)
println("sqrt(144.0) = ", sqrt(144.0))
"""
            ),

            # Output pane
            Div(:class => "flex flex-col bg-warm-950 dark:bg-warm-950",
                :style => "height: 220px; min-height: 80px;",
                Div(:class => "flex items-center justify-between px-3 py-1.5 border-b border-warm-800 bg-warm-900",
                    Span(:class => "text-xs text-warm-400", "Output"),
                    Button(:id => "pg-clear",
                        :class => "text-xs text-warm-500 hover:text-warm-300 bg-transparent border-none cursor-pointer",
                        "Clear"
                    ),
                ),
                Div(:id => "pg-output",
                    :class => "flex-1 overflow-auto px-3 py-2 font-mono text-sm text-warm-300 whitespace-pre-wrap break-all",
                    Span(:class => "italic text-warm-500", "Press Run or Ctrl+Enter to compile and execute.")
                )
            ),
        ),

        # Playground logic — zero external deps
        Script(_playground_script())
    )
end

function _playground_script()
    raw"""
    const editor = document.getElementById("pg-editor");
    const runBtn = document.getElementById("pg-run");
    const statusEl = document.getElementById("pg-status");
    const outputEl = document.getElementById("pg-output");
    const clearBtn = document.getElementById("pg-clear");

    // Tab key inserts spaces instead of changing focus
    editor.addEventListener("keydown", (e) => {
      if (e.key === "Tab") {
        e.preventDefault();
        const start = editor.selectionStart;
        editor.value = editor.value.substring(0, start) + "    " + editor.value.substring(editor.selectionEnd);
        editor.selectionStart = editor.selectionEnd = start + 4;
      }
      if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
        e.preventDefault();
        runCode();
      }
    });

    clearBtn.onclick = () => { outputEl.innerHTML = ""; };

    function appendOutput(text, cls) {
      const span = document.createElement("span");
      if (cls === "error") span.style.color = "#f38ba8";
      else if (cls === "info") { span.style.color = "#a6adc8"; span.style.fontStyle = "italic"; }
      span.textContent = text;
      outputEl.appendChild(span);
      outputEl.scrollTop = outputEl.scrollHeight;
    }

    const EXEC_TIMEOUT_MS = 5000;
    let activeWorker = null, activeTimer = null;

    function cleanupWorker() {
      if (activeTimer) { clearTimeout(activeTimer); activeTimer = null; }
      if (activeWorker) { activeWorker.terminate(); activeWorker = null; }
    }

    function createWorker() {
      const code = `
        self.onmessage = async (e) => {
          if (e.data.type !== "run") return;
          const importObject = {
            "io": {
              "write_string": (s) => self.postMessage({ type: "stdout", data: s }),
              "write_int": (n) => self.postMessage({ type: "stdout", data: String(n) }),
              "write_float": (f) => self.postMessage({ type: "stdout", data: String(f) }),
              "write_bool": (b) => self.postMessage({ type: "stdout", data: b ? "true" : "false" }),
              "write_newline": () => self.postMessage({ type: "stdout", data: "\\n" }),
              "write_nothing": () => self.postMessage({ type: "stdout", data: "nothing" }),
            },
            "Math": { "pow": Math.pow },
            "env": {
              "capture_stack": () => null,
              "perf_now": () => performance.now(),
              "random_i64": () => BigInt(Math.floor(Math.random() * 2**63)),
            },
          };
          try {
            const mod = await WebAssembly.compile(new Uint8Array(e.data.wasm), { builtins: ['js-string'] });
            const instance = await WebAssembly.instantiate(mod, importObject);
            const t0 = performance.now();
            if (instance.exports.main) {
              instance.exports.main();
            } else {
              const fns = Object.keys(instance.exports).filter(k => typeof instance.exports[k] === 'function');
              self.postMessage({ type: "stdout", data: "Exported: " + fns.join(", ") + "\\n" });
            }
            self.postMessage({ type: "done", execTime: performance.now() - t0 });
          } catch (err) {
            self.postMessage({ type: "error", error: err.message, stack: err.stack });
          }
        };
      `;
      return new Worker(URL.createObjectURL(new Blob([code], { type: "application/javascript" })));
    }

    // Auto-detect compile server
    let COMPILE_URL = window.location.origin;
    fetch(COMPILE_URL + "/health", { signal: AbortSignal.timeout(1000) })
      .then(r => { if (!r.ok) throw 0; })
      .catch(() => { COMPILE_URL = "http://localhost:8080"; });

    async function runCode() {
      const code = editor.value;
      if (!code.trim()) return;

      cleanupWorker();
      outputEl.innerHTML = "";
      runBtn.disabled = true;
      statusEl.textContent = "Compiling...";

      try {
        const t0 = performance.now();
        const resp = await fetch(COMPILE_URL + "/compile", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ code }),
        });

        if (!resp.ok) {
          const err = await resp.json();
          statusEl.textContent = "Compile error";
          appendOutput("Compile error: " + (err.error || err.message || "Unknown error") + "\n", "error");
          runBtn.disabled = false;
          return;
        }

        const wasmBytes = await resp.arrayBuffer();
        const compileTime = performance.now() - t0;
        statusEl.textContent = "Compiled (" + (compileTime / 1000).toFixed(2) + "s, " + (wasmBytes.byteLength / 1024).toFixed(1) + " KB)";
        appendOutput("[Compiled " + (wasmBytes.byteLength / 1024).toFixed(1) + " KB in " + (compileTime / 1000).toFixed(2) + "s]\n", "info");

        statusEl.textContent += " | Executing...";
        const worker = createWorker();
        activeWorker = worker;

        activeTimer = setTimeout(() => {
          worker.terminate();
          activeWorker = null; activeTimer = null;
          appendOutput("\n[Execution timed out after " + (EXEC_TIMEOUT_MS / 1000) + "s]\n", "error");
          statusEl.textContent += " | Timed out";
          runBtn.disabled = false;
        }, EXEC_TIMEOUT_MS);

        worker.onmessage = (e) => {
          const msg = e.data;
          if (msg.type === "stdout") { appendOutput(msg.data); }
          else if (msg.type === "done") {
            cleanupWorker();
            appendOutput("\n[Executed in " + msg.execTime.toFixed(1) + "ms]\n", "info");
            statusEl.textContent += " | Executed (" + msg.execTime.toFixed(1) + "ms)";
            runBtn.disabled = false;
          } else if (msg.type === "error") {
            cleanupWorker();
            appendOutput("Runtime error: " + msg.error + "\n", "error");
            statusEl.textContent = "Runtime error";
            runBtn.disabled = false;
          }
        };

        worker.onerror = (e) => {
          cleanupWorker();
          appendOutput("Worker error: " + e.message + "\n", "error");
          statusEl.textContent = "Worker error";
          runBtn.disabled = false;
        };

        worker.postMessage({ type: "run", wasm: wasmBytes }, [wasmBytes]);

      } catch (e) {
        cleanupWorker();
        if (e instanceof TypeError && e.message.includes("fetch")) {
          appendOutput("Compile server not available.\n", "error");
          appendOutput("Start it with: julia +1.12 --project=. scripts/serve.jl\n", "info");
        } else {
          appendOutput("Error: " + e.message + "\n", "error");
        }
        statusEl.textContent = "Error";
        runBtn.disabled = false;
      }
    }

    runBtn.onclick = runCode;
    editor.focus();
    """
end

# Export
PlaygroundPage
