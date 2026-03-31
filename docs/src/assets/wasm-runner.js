// WasmTarget.jl docs — live WASM demo runner
// Loads pre-compiled .wasm files and runs exported functions in the browser.

document.addEventListener("DOMContentLoaded", function() {
  var demos = document.querySelectorAll("[data-wasm-demo]");
  for (var i = 0; i < demos.length; i++) {
    initDemo(demos[i]);
  }
});

function getAssetsBase() {
  // Find the path to assets/ relative to current page.
  // Documenter.jl copies assets to {build}/assets/. Pages can be at any depth.
  // We look for the <link> tag that loads the Documenter CSS to find the relative prefix.
  var links = document.querySelectorAll('link[rel="stylesheet"]');
  for (var i = 0; i < links.length; i++) {
    var href = links[i].getAttribute("href") || "";
    var idx = href.indexOf("assets/");
    if (idx !== -1) {
      return href.substring(0, idx) + "assets/examples/";
    }
  }
  // Fallback: try common patterns
  return "../assets/examples/";
}

function initDemo(container) {
  var file = container.getAttribute("data-wasm-demo");
  var func = container.getAttribute("data-wasm-func") || file;
  var argsRaw = container.getAttribute("data-wasm-args") || "";
  var isBigInt = container.getAttribute("data-wasm-bigint") === "true";

  var btn = container.querySelector("button");
  var output = container.querySelector("pre.wasm-output");
  if (!btn || !output) return;

  btn.addEventListener("click", function() {
    btn.disabled = true;
    output.textContent = "Loading WASM...";

    var url = getAssetsBase() + file + ".wasm";

    fetch(url)
      .then(function(response) {
        if (!response.ok) throw new Error("HTTP " + response.status + " fetching " + url);
        return response.arrayBuffer();
      })
      .then(function(bytes) {
        // Provide standard imports that WasmTarget modules may need
        var imports = {
          Math: { pow: Math.pow },
          console: { log: function() {} }
        };
        return WebAssembly.instantiate(bytes, imports);
      })
      .then(function(result) {
        var args = parseArgs(argsRaw, isBigInt);
        var exportFn = result.instance.exports[func];
        if (!exportFn) throw new Error("Export '" + func + "' not found. Available: " + Object.keys(result.instance.exports).join(", "));
        var val = exportFn.apply(null, args);
        output.textContent = formatResult(val);
        output.style.color = "#2d7d2d";
      })
      .catch(function(err) {
        output.textContent = "Error: " + err.message;
        output.style.color = "#d32f2f";
      })
      .finally(function() {
        btn.disabled = false;
      });
  });
}

function parseArgs(raw, isBigInt) {
  if (!raw) return [];
  return raw.split(",").map(function(s) {
    s = s.trim();
    if (isBigInt) return BigInt(s);
    if (s.includes(".")) return parseFloat(s);
    return parseInt(s, 10);
  });
}

function formatResult(val) {
  if (typeof val === "bigint") return "Result: " + val.toString();
  if (typeof val === "number") {
    if (Number.isInteger(val)) return "Result: " + val.toString();
    return "Result: " + val.toPrecision(15);
  }
  return "Result: " + String(val);
}
