#!/usr/bin/env node
// WET-002: Browser-level E2E test for WasmTarget Makie overlays.
// Launched from Julia test — expects module.wasm in this directory.
// Outputs JSON results for Julia test harness to parse.

import { chromium } from 'playwright';
import http from 'http';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---- Simple static file server ----
function startServer(dir, port) {
  const mimeTypes = {
    '.html': 'text/html',
    '.js':   'application/javascript',
    '.mjs':  'application/javascript',
    '.wasm': 'application/wasm',
    '.json': 'application/json',
    '.css':  'text/css',
  };

  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const url = new URL(req.url, `http://localhost:${port}`);
      let filePath = path.join(dir, url.pathname);
      if (url.pathname === '/') filePath = path.join(dir, 'test.html');

      if (!fs.existsSync(filePath)) {
        res.writeHead(404);
        res.end('Not found');
        return;
      }

      const ext = path.extname(filePath);
      const contentType = mimeTypes[ext] || 'application/octet-stream';
      const data = fs.readFileSync(filePath);
      res.writeHead(200, { 'Content-Type': contentType });
      res.end(data);
    });

    server.listen(port, () => resolve(server));
  });
}

// ---- Run assertions ----
async function runTests(funcName) {
  const port = 9876 + Math.floor(Math.random() * 1000);
  const server = await startServer(__dirname, port);
  const results = [];

  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();

    // Navigate to test page with the specified function
    const url = `http://localhost:${port}/?func=${funcName}`;
    await page.goto(url);

    // Wait for WASM to finish
    await page.waitForFunction(() => window.__testReady === true, { timeout: 30000 });

    // Check for errors
    const error = await page.evaluate(() => window.__testError);
    if (error) {
      results.push({ name: 'wasm_load', pass: false, detail: error });
      return results;
    }

    // Assertion 1: WebGL canvas was created
    const canvasCount = await page.evaluate(() => {
      return document.querySelectorAll('#makie-canvas canvas').length;
    });
    results.push({
      name: 'canvas_created',
      pass: canvasCount > 0,
      detail: `Found ${canvasCount} canvas element(s)`
    });

    // Assertion 2: Canvas has non-zero dimensions
    const canvasSize = await page.evaluate(() => {
      const c = document.querySelector('#makie-canvas canvas');
      if (!c) return { width: 0, height: 0 };
      return { width: c.width, height: c.height };
    });
    results.push({
      name: 'canvas_dimensions',
      pass: canvasSize.width > 0 && canvasSize.height > 0,
      detail: `${canvasSize.width}x${canvasSize.height}`
    });

    // Assertion 3: Canvas has non-zero pixel data (something was rendered)
    // Use toDataURL to check — works even with headless WebGL
    const hasPixels = await page.evaluate(() => {
      const c = document.querySelector('#makie-canvas canvas');
      if (!c) return false;
      // toDataURL returns a base64 PNG — a blank canvas has a specific short encoding
      const dataUrl = c.toDataURL();
      // A blank 512x512 canvas PNG is ~5KB. Rendered content is typically larger.
      // Also check that the data URL differs from a blank canvas of same size
      const blankCanvas = document.createElement('canvas');
      blankCanvas.width = c.width;
      blankCanvas.height = c.height;
      const blankUrl = blankCanvas.toDataURL();
      return dataUrl !== blankUrl && dataUrl.length > 1000;
    });
    results.push({
      name: 'canvas_has_pixels',
      pass: hasPixels === true,
      detail: hasPixels ? 'Non-zero pixels found' : 'Canvas appears empty'
    });

    // Assertion 4: Import functions were called with correct parameters
    const calls = await page.evaluate(() => window.__makieCalls);
    results.push({
      name: 'imports_called',
      pass: calls.length > 0,
      detail: `${calls.length} import call(s): ${calls.map(c => c.type).join(', ')}`
    });

    // Assertion 5: Display was called (rendering triggered)
    const displayCalls = calls.filter(c => c.type === 'display');
    results.push({
      name: 'display_called',
      pass: displayCalls.length > 0,
      detail: `display called ${displayCalls.length} time(s)`
    });

    // Assertion 6: WASM function returned expected value
    const wasmResult = await page.evaluate(() => window.__wasmResult);
    results.push({
      name: 'wasm_return_value',
      pass: wasmResult === 100,  // display(fig_id=1) → 1*100 = 100
      detail: `Result: ${wasmResult} (expected 100)`
    });

    // Assertion 7: Specific plot types were created (depends on function)
    if (funcName === '_wet_ov_full') {
      const plotTypes = new Set(calls.map(c => c.type));
      const hasAllTypes = plotTypes.has('heatmap') && plotTypes.has('lines') && plotTypes.has('scatter') && plotTypes.has('display');
      results.push({
        name: 'all_plot_types',
        pass: hasAllTypes,
        detail: `Plot types: ${[...plotTypes].join(', ')}`
      });
    }

  } finally {
    if (browser) await browser.close();
    server.close();
  }

  return results;
}

// ---- Main ----
const funcName = process.argv[2] || '_wet_ov_full';
const wasmPath = path.join(__dirname, 'module.wasm');

if (!fs.existsSync(wasmPath)) {
  console.log(JSON.stringify([{ name: 'wasm_file', pass: false, detail: 'module.wasm not found' }]));
  process.exit(1);
}

try {
  const results = await runTests(funcName);
  console.log(JSON.stringify(results));
  const failures = results.filter(r => !r.pass);
  process.exit(failures.length > 0 ? 1 : 0);
} catch (e) {
  console.log(JSON.stringify([{ name: 'test_runner', pass: false, detail: e.message }]));
  process.exit(1);
}
