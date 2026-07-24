import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { mkdir, readFile } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { chromium, firefox } from "playwright";

const root = resolve(process.argv[2] ?? "");
if (!process.argv[2]) {
  throw new Error("usage: node jump_t0.mjs EXPORT_ROOT");
}
const exportsEvidence = JSON.parse(
  await readFile(resolve(root, "exports.json"), "utf8"),
);
const playwrightPackage = JSON.parse(
  await readFile(new URL("./node_modules/playwright/package.json", import.meta.url), "utf8"),
);

const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".wasm", "application/wasm"],
]);

const server = createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    const requested = resolve(root, `.${pathname}`);
    if (requested !== root && !requested.startsWith(`${root}${sep}`)) {
      response.writeHead(403).end("forbidden");
      return;
    }
    const bytes = await readFile(requested);
    response.writeHead(200, {
      "content-type": contentTypes.get(extname(requested)) ?? "application/octet-stream",
      "cache-control": "no-store",
    });
    response.end(bytes);
  } catch (error) {
    response.writeHead(error?.code === "ENOENT" ? 404 : 500).end(String(error));
  }
});

await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();

const targets = [
  {
    delivery: "split-http",
    url: `http://127.0.0.1:${port}/split/00_moi_values.html`,
  },
  {
    delivery: "single-file",
    url: pathToFileURL(resolve(root, "portable", "00_moi_values.html")).href,
  },
];
const negativeTargets = [
  {
    delivery: "negative-split-http",
    url: `http://127.0.0.1:${port}/negative/00_negative_unsupported.html`,
  },
  {
    delivery: "negative-single-file",
    url: pathToFileURL(
      resolve(root, "negative_portable", "00_negative_unsupported.html"),
    ).href,
  },
];
const evidenceDir = resolve(root, "browser-evidence");
await mkdir(evidenceDir, { recursive: true });
const engines = [
  ["chromium", chromium],
  ["firefox", firefox],
];
const expectedCases = new Map([
  ["moi_affine_value", "7.0"],
  ["moi_quadratic_value", "-0.5"],
  ["moi_set_value", "10.25"],
  ["ordered_dict_value", "65"],
]);

function canonicalOS(platform) {
  if (platform === "win32") return "windows";
  if (platform === "darwin") return "macos";
  if (platform === "linux") return "linux";
  return "unsupported";
}

function canonicalArch(arch) {
  if (arch === "x64") return "x86_64";
  if (arch === "arm64") return "aarch64";
  return arch;
}

async function waitForValues(page, expected, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let actual = [];
  while (Date.now() < deadline) {
    actual = await page.locator("table strong").allTextContents();
    if (
      actual.length === expected.length &&
      actual.every((value, index) => value.trim() === expected[index])
    ) {
      return actual;
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`timed out waiting for ${JSON.stringify(expected)}; got ${JSON.stringify(actual)}`);
}

async function readCases(page) {
  const rows = await page.locator("[data-wt-jump-case]").evaluateAll((elements) =>
    elements.map((element) => [
      element.getAttribute("data-wt-jump-case"),
      element.textContent?.trim() ?? "",
    ]),
  );
  return Object.fromEntries(rows);
}

async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

const evidence = [];
try {
  for (const [engineName, engine] of engines) {
    const browser = await engine.launch({ headless: true });
    try {
      for (const target of targets) {
        const page = await browser.newPage();
        const pageErrors = [];
        const consoleErrors = [];
        const failedRequests = [];
        page.on("pageerror", (error) => pageErrors.push(String(error)));
        page.on("console", (message) => {
          if (message.type() === "error") consoleErrors.push(message.text());
        });
        page.on("requestfailed", (request) => {
          failedRequests.push(`${request.url()}: ${request.failure()?.errorText ?? "unknown"}`);
        });
        await page.goto(target.url, { waitUntil: "load" });
        await waitForValues(page, ["6.25", "-0.125", "9.75", "61"]);
        const sliders = page.locator('input[type="range"]');
        if (await sliders.count() !== 1) {
          throw new Error(`${engineName}/${target.delivery} expected exactly one slider`);
        }
        const slider = sliders.first();
        await slider.evaluate((element) => {
          element.value = "41"; // -8:0.25:8 => 2.0
          element.dispatchEvent(new Event("input", { bubbles: true }));
        });
        const values = await waitForValues(page, ["7.0", "-0.5", "10.25", "65"]);
        const observedCases = await readCases(page);
        if (
          Object.keys(observedCases).length !== expectedCases.size ||
          [...expectedCases].some(([caseId, value]) => observedCases[caseId] !== value)
        ) {
          throw new Error(
            `${engineName}/${target.delivery} case ledger mismatch: ` +
            JSON.stringify(observedCases),
          );
        }
        if (pageErrors.length > 0) {
          throw new Error(`${engineName}/${target.delivery} page errors: ${pageErrors.join("; ")}`);
        }
        if (consoleErrors.length > 0) {
          throw new Error(`${engineName}/${target.delivery} console errors: ${consoleErrors.join("; ")}`);
        }
        if (failedRequests.length > 0) {
          throw new Error(`${engineName}/${target.delivery} failed requests: ${failedRequests.join("; ")}`);
        }
        const screenshot = `${engineName}-${target.delivery}.png`;
        await page.screenshot({
          path: resolve(evidenceDir, screenshot),
          fullPage: true,
        });
        const screenshotPath = resolve(evidenceDir, screenshot);
        evidence.push({
          browser: engineName,
          browser_version: browser.version(),
          delivery: target.delivery,
          expected_input: 2.0,
          observed_values: values,
          observed_cases: observedCases,
          screenshot,
          screenshot_sha256: await sha256File(screenshotPath),
          pass: true,
        });
        await page.close();
      }

      for (const target of negativeTargets) {
        const page = await browser.newPage();
        const pageErrors = [];
        const consoleErrors = [];
        const failedRequests = [];
        page.on("pageerror", (error) => pageErrors.push(String(error)));
        page.on("console", (message) => {
          if (message.type() === "error") consoleErrors.push(message.text());
        });
        page.on("requestfailed", (request) => {
          failedRequests.push(`${request.url()}: ${request.failure()?.errorText ?? "failed"}`);
        });
        await page.goto(target.url, { waitUntil: "load" });
        const status = page.locator(".pss-island-fallback-bond-status");
        await status.waitFor({ state: "visible" });
        const statusText = (await status.textContent())?.trim() ?? "";
        if (!statusText.includes("static in this export")) {
          throw new Error(
            `${engineName}/${target.delivery} missing explicit static status: ${statusText}`,
          );
        }
        const output = page.locator("#out-0b000004-0000-4000-8000-000000000004");
        const staticValue = () => output.evaluate((element) =>
          [...element.childNodes]
            .filter((node) => node.nodeType === Node.TEXT_NODE)
            .map((node) => node.textContent ?? "")
            .join("")
            .trim(),
        );
        const before = await staticValue();
        const slider = page.locator('input[type="range"]').first();
        await slider.evaluate((element) => {
          element.value = "8";
          element.dispatchEvent(new Event("input", { bubbles: true }));
        });
        await page.waitForTimeout(250);
        const after = await staticValue();
        if (before !== "10.5" || after !== before) {
          throw new Error(
            `${engineName}/${target.delivery} expected an explicit static value of 10.5; ` +
            `before=${before} after=${after}`,
          );
        }
        if (pageErrors.length || consoleErrors.length || failedRequests.length) {
          throw new Error(
            `${engineName}/${target.delivery} runtime failures: ` +
            JSON.stringify({ pageErrors, consoleErrors, failedRequests }),
          );
        }
        const screenshot = `${engineName}-${target.delivery}.png`;
        await page.screenshot({
          path: resolve(evidenceDir, screenshot),
          fullPage: true,
        });
        const screenshotPath = resolve(evidenceDir, screenshot);
        evidence.push({
          browser: engineName,
          browser_version: browser.version(),
          delivery: target.delivery,
          expected_failure: "unsupported_method",
          observed_status: statusText,
          observed_static_value: after,
          screenshot,
          screenshot_sha256: await sha256File(screenshotPath),
          pass: true,
        });
        await page.close();
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await new Promise((resolveClose) => server.close(resolveClose));
}

console.log(JSON.stringify({
  schema: 2,
  pass: true,
  wt_sha: exportsEvidence.wt_sha,
  wasmtarget: exportsEvidence.wasmtarget,
  snapshot: exportsEvidence.snapshot,
  binaryen_jll: exportsEvidence.binaryen_jll,
  source_contract: exportsEvidence.source_contract,
  validator: exportsEvidence.validator,
  export_runtime: exportsEvidence.runtime,
  browser_runtime: {
    node: process.version,
    playwright: playwrightPackage.version,
    os: canonicalOS(process.platform),
    canonical_arch: canonicalArch(process.arch),
    platform: process.platform,
    arch: process.arch,
  },
  manifest_sha256: exportsEvidence.manifest_sha256,
  report_sha256: {
    split: exportsEvidence.split.report_sha256,
    portable: exportsEvidence.portable.report_sha256,
  },
  positive: {
    split_judgement: exportsEvidence.split.judgement,
    portable_judgement: exportsEvidence.portable.judgement,
    split_cells: exportsEvidence.split.cells,
    portable_cells: exportsEvidence.portable.cells,
  },
  negative: {
    judgement: exportsEvidence.negative.judgement,
    portable_judgement: exportsEvidence.negative_portable.judgement,
    diagnostic_kind: exportsEvidence.negative.diagnostic_kind,
    portable_diagnostic_kind: exportsEvidence.negative_portable.diagnostic_kind,
    report_sha256: exportsEvidence.negative.report_sha256,
    portable_report_sha256: exportsEvidence.negative_portable.report_sha256,
  },
  evidence,
}, null, 2));
