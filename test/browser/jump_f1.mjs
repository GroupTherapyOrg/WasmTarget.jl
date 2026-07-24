import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { isAbsolute, extname, relative, resolve, sep } from "node:path";
import { readFile, mkdir, realpath, lstat } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { chromium, firefox } from "playwright";

if (!process.argv[2]) {
  throw new Error("usage: node jump_f1.mjs EXPORT_ROOT");
}
const root = await realpath(resolve(process.argv[2]));
const realRoot = root;

async function rejectSymlinkComponents(path, { allowMissingLeaf = false } = {}) {
  const back = relative(root, path);
  if (!back || back.startsWith(`..${sep}`) || back === "..") {
    throw new Error(`path escapes artifact root: ${path}`);
  }
  const components = back.split(sep);
  let current = root;
  for (const [index, component] of components.entries()) {
    current = resolve(current, component);
    try {
      const stat = await lstat(current);
      if (stat.isSymbolicLink()) {
        throw new Error(`artifact path contains a symlink: ${current}`);
      }
    } catch (error) {
      const isMissingAllowed =
        allowMissingLeaf &&
        index === components.length - 1 &&
        error?.code === "ENOENT";
      if (!isMissingAllowed) throw error;
    }
  }
}

async function artifactPath(relativePath) {
  if (
    typeof relativePath !== "string" ||
    isAbsolute(relativePath) ||
    relativePath.includes("\\")
  ) {
    throw new Error(`unsafe artifact path: ${JSON.stringify(relativePath)}`);
  }
  const path = resolve(root, relativePath);
  const back = relative(root, path);
  if (!back || back.startsWith(`..${sep}`) || back === "..") {
    throw new Error(`artifact path escapes root: ${relativePath}`);
  }
  await rejectSymlinkComponents(path);
  const canonical = await realpath(path);
  const canonicalBack = relative(realRoot, canonical);
  if (
    !canonicalBack ||
    canonicalBack.startsWith(`..${sep}`) ||
    canonicalBack === ".."
  ) {
    throw new Error(`artifact symlink escapes root: ${relativePath}`);
  }
  return canonical;
}

async function outputArtifactPath(relativePath) {
  if (
    typeof relativePath !== "string" ||
    isAbsolute(relativePath) ||
    relativePath.includes("\\")
  ) {
    throw new Error(`unsafe output path: ${JSON.stringify(relativePath)}`);
  }
  const path = resolve(root, relativePath);
  const back = relative(root, path);
  if (!back || back.startsWith(`..${sep}`) || back === "..") {
    throw new Error(`output path escapes root: ${relativePath}`);
  }
  await rejectSymlinkComponents(path, { allowMissingLeaf: true });
  const canonicalParent = await realpath(resolve(path, ".."));
  const parentBack = relative(realRoot, canonicalParent);
  if (
    parentBack.startsWith(`..${sep}`) ||
    parentBack === ".."
  ) {
    throw new Error(`output parent symlink escapes root: ${relativePath}`);
  }
  return path;
}

const exportsPath = await artifactPath("exports.json");
const exportsEvidence = JSON.parse(await readFile(exportsPath, "utf8"));
const expectedVersions = exportsEvidence.expected_versions;
const resourceContract = exportsEvidence.resource_contract;
const playwrightPackage = JSON.parse(
  await readFile(
    new URL("./node_modules/playwright/package.json", import.meta.url),
    "utf8",
  ),
);
if (process.version !== `v${expectedVersions.node}`) {
  throw new Error(
    `wrong Node version: ${process.version}; expected v${expectedVersions.node}`,
  );
}
if (playwrightPackage.version !== expectedVersions.playwright) {
  throw new Error(
    `wrong Playwright version: ${playwrightPackage.version}; ` +
      `expected ${expectedVersions.playwright}`,
  );
}

const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".wasm", "application/wasm"],
]);
const server = createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(
      new URL(request.url, "http://localhost").pathname,
    );
    const requested = resolve(root, `.${pathname}`);
    const back = relative(root, requested);
    if (back.startsWith(`..${sep}`) || back === "..") {
      response.writeHead(403).end("forbidden");
      return;
    }
    await rejectSymlinkComponents(requested);
    const canonicalRequested = await realpath(requested);
    const canonicalBack = relative(realRoot, canonicalRequested);
    if (
      canonicalBack.startsWith(`..${sep}`) ||
      canonicalBack === ".."
    ) {
      response.writeHead(403).end("forbidden");
      return;
    }
    const bytes = await readFile(canonicalRequested);
    response.writeHead(200, {
      "content-type":
        contentTypes.get(extname(canonicalRequested)) ??
        "application/octet-stream",
      "cache-control": "no-store",
    });
    response.end(bytes);
  } catch (error) {
    response
      .writeHead(error?.code === "ENOENT" ? 404 : 500)
      .end(String(error));
  }
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const { port } = server.address();

const stages = [
  {
    stage: "f1a",
    bondCount: 2,
    controls: ["state", "x_slot"],
    defaults: { state: 1, x_slot: 5 },
  },
  {
    stage: "f1b",
    bondCount: 2,
    controls: ["mode", "boundary"],
    defaults: { mode: 1, boundary: 3 },
  },
];
const engines = [
  ["chromium", chromium, expectedVersions.chromium],
  ["firefox", firefox, expectedVersions.firefox],
];
const evidenceDir = resolve(root, "browser-evidence");
await mkdir(evidenceDir, { recursive: true });

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

async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function readCases(page) {
  const rows = await page
    .locator("[data-wt-jump-case]")
    .evaluateAll((elements) =>
      elements.map((element) => [
        element.getAttribute("data-wt-jump-case"),
        element.textContent?.trim() ?? "",
      ]),
    );
  return Object.fromEntries(rows);
}

async function waitForCases(page, expected, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let actual = {};
  while (Date.now() < deadline) {
    actual = await readCases(page);
    if (
      Object.keys(actual).length === Object.keys(expected).length &&
      Object.entries(expected).every(([key, value]) => actual[key] === value)
    ) {
      return actual;
    }
    await page.waitForTimeout(20);
  }
  throw new Error(
    `timed out waiting for ${JSON.stringify(expected)}; ` +
      `got ${JSON.stringify(actual)}`,
  );
}

async function setControls(page, spec, controls) {
  await page.locator('input[type="range"]').evaluateAll(
    (elements, payload) => {
      for (const [index, name] of payload.names.entries()) {
        elements[index].value = String(payload.controls[name]);
      }
      // A single bond event observes one coherent state vector. Dispatching
      // every control back-to-back can intentionally coalesce intermediate
      // generations in the island runtime and would test scheduler races
      // rather than the requested canonical input.
      elements[payload.names.length - 1].dispatchEvent(
        new Event("input", { bubbles: true }),
      );
    },
    { names: spec.controls, controls },
  );
}

function sameControls(actual, expected) {
  return Object.entries(expected).every(
    ([name, value]) => Number(actual[name]) === Number(value),
  );
}

async function runCorpus(page, spec, corpus) {
  const observations = [];
  for (const row of corpus) {
    await setControls(page, spec, row.controls);
    const observed = await waitForCases(page, row.expected);
    observations.push({
      controls: row.controls,
      semantic_inputs: row.semantic_inputs,
      observed,
    });
  }
  return observations;
}

async function wasmMetrics(page) {
  return page.evaluate(() => globalThis.__wtWasmMetrics);
}

async function domMetrics(page) {
  return page.evaluate(() => ({
    bonds: document.querySelectorAll("bond").length,
    cases: document.querySelectorAll("[data-wt-jump-case]").length,
    outputs: document.querySelectorAll("pluto-output").length,
  }));
}

const evidence = [];
try {
  for (const [browserName, browserType, expectedBrowserVersion] of engines) {
    const browser = await browserType.launch({ headless: true });
    const browserVersion = browser.version();
    if (browserVersion !== expectedBrowserVersion) {
      await browser.close();
      throw new Error(
        `wrong ${browserName} version: ${browserVersion}; ` +
          `expected ${expectedBrowserVersion}`,
      );
    }
    try {
      for (const spec of stages) {
        const corpus = exportsEvidence.expected_ledger[spec.stage];
        const initialRow = corpus.find((row) =>
          sameControls(row.controls, spec.defaults),
        );
        if (!initialRow) {
          throw new Error(`${spec.stage} ledger has no default row`);
        }
        const targets = [
          {
            delivery: "split-http",
            url:
              `http://127.0.0.1:${port}/` +
              exportsEvidence[spec.stage].split.html,
            expectedWasmRequests:
              resourceContract.split_wasm_requests_per_page,
          },
          {
            delivery: "single-file",
            url: pathToFileURL(
              await artifactPath(exportsEvidence[spec.stage].portable.html),
            ).href,
            expectedWasmRequests:
              resourceContract.single_file_wasm_requests_per_page,
          },
        ];
        for (const target of targets) {
          const freshPages = [];
          for (
            let fresh = 0;
            fresh < resourceContract.fresh_pages;
            fresh += 1
          ) {
            const context = await browser.newContext();
            const page = await context.newPage();
            const pageErrors = [];
            const consoleErrors = [];
            const failedRequests = [];
            const requests = [];
            const wasmResponseDigests = [];
            page.on("pageerror", (error) => pageErrors.push(String(error)));
            page.on("console", (message) => {
              if (message.type() === "error") {
                consoleErrors.push(message.text());
              }
            });
            page.on("request", (request) => requests.push(request.url()));
            page.on("requestfailed", (request) => {
              failedRequests.push(
                `${request.url()}: ` +
                  `${request.failure()?.errorText ?? "unknown"}`,
              );
            });
            page.on("response", (response) => {
              if (new URL(response.url()).pathname.endsWith(".wasm")) {
                wasmResponseDigests.push(
                  response.body().then((bytes) =>
                    createHash("sha256").update(bytes).digest("hex"),
                  ),
                );
              }
            });
            await page.addInitScript(() => {
              const metrics = {
                compile: 0,
                compileStreaming: 0,
                instantiate: 0,
                instantiateStreaming: 0,
              };
              globalThis.__wtWasmMetrics = metrics;
              for (const name of Object.keys(metrics)) {
                const original = WebAssembly[name];
                if (typeof original !== "function") continue;
                WebAssembly[name] = function (...args) {
                  metrics[name] += 1;
                  return Reflect.apply(original, this, args);
                };
              }
            });
            await page.goto(target.url, { waitUntil: "load" });
            const initial = await waitForCases(page, initialRow.expected);
            const sliders = page.locator('input[type="range"]');
            if ((await sliders.count()) !== spec.bondCount) {
              throw new Error(
                `${browserName}/${spec.stage}/${target.delivery} ` +
                  `expected ${spec.bondCount} slider(s)`,
              );
            }
            const initialControls = Object.fromEntries(
              await sliders.evaluateAll((elements, names) =>
                elements.map((element, index) => [
                  names[index],
                  Number(element.value),
                ]),
              spec.controls),
            );
            if (!sameControls(initialControls, spec.defaults)) {
              throw new Error(
                `${browserName}/${spec.stage}/${target.delivery} ` +
                  `wrong initial controls ${JSON.stringify(initialControls)}`,
              );
            }
            const initialDOM = await domMetrics(page);
            if (
              initialDOM.bonds !== spec.bondCount ||
              initialDOM.cases !== Object.keys(initialRow.expected).length
            ) {
              throw new Error(
                `${browserName}/${spec.stage}/${target.delivery} ` +
                  `unexpected DOM topology ${JSON.stringify(initialDOM)}`,
              );
            }
            const rounds = [];
            for (
              let round = 0;
              round < resourceContract.same_page_rounds;
              round += 1
            ) {
              const observations = await runCorpus(page, spec, corpus);
              const afterDOM = await domMetrics(page);
              if (JSON.stringify(afterDOM) !== JSON.stringify(initialDOM)) {
                throw new Error(
                  `${browserName}/${spec.stage}/${target.delivery} ` +
                    `DOM topology changed in round ${round + 1}`,
                );
              }
              rounds.push({
                round: round + 1,
                transitions: observations.length,
                observations,
                dom: afterDOM,
              });
            }
            const runtimeMetrics = await wasmMetrics(page);
            const compileCalls =
              runtimeMetrics.compile + runtimeMetrics.compileStreaming;
            const instantiateCalls =
              runtimeMetrics.instantiate +
              runtimeMetrics.instantiateStreaming;
            const wasmRequests = requests.filter((url) =>
              new URL(url).pathname.endsWith(".wasm"),
            ).length;
            const deliveredWasmDigests =
              await Promise.all(wasmResponseDigests);
            if (
              compileCalls !==
                resourceContract.wasm_compile_calls_per_page ||
              instantiateCalls !==
                resourceContract.wasm_instantiate_calls_per_page ||
              wasmRequests !== target.expectedWasmRequests
            ) {
              throw new Error(
                `${browserName}/${spec.stage}/${target.delivery} ` +
                  `resource proxy mismatch ${JSON.stringify({
                    runtimeMetrics,
                    wasmRequests,
                    expectedWasmRequests: target.expectedWasmRequests,
                  })}`,
              );
            }
            if (
              pageErrors.length ||
              consoleErrors.length ||
              failedRequests.length
            ) {
              throw new Error(
                `${browserName}/${spec.stage}/${target.delivery} ` +
                  `runtime failures: ${JSON.stringify({
                    pageErrors,
                    consoleErrors,
                    failedRequests,
                  })}`,
              );
            }
            let screenshot = null;
            let screenshotSha256 = null;
            if (fresh === resourceContract.fresh_pages - 1) {
              screenshot =
                `browser-evidence/${browserName}-${spec.stage}-` +
                `${target.delivery}.png`;
              const screenshotPath = await outputArtifactPath(screenshot);
              await page.screenshot({
                path: screenshotPath,
                fullPage: true,
              });
              screenshotSha256 = await sha256File(screenshotPath);
            }
            const instanceEvidence = {
              instance: fresh + 1,
              initial_controls: initialControls,
              initial_cases: initial,
              rounds,
              wasm_runtime_calls: runtimeMetrics,
              wasm_requests: wasmRequests,
              wasm_response_sha256: deliveredWasmDigests,
              dom: initialDOM,
              page_errors: pageErrors,
              console_errors: consoleErrors,
              failed_requests: failedRequests,
              screenshot,
              screenshot_sha256: screenshotSha256,
              page_closed: false,
              context_pages_after_page_close: null,
              context_closed: false,
            };
            await page.close();
            instanceEvidence.page_closed = page.isClosed();
            instanceEvidence.context_pages_after_page_close =
              context.pages().length;
            await context.close();
            instanceEvidence.context_closed = true;
            freshPages.push(instanceEvidence);
          }
          evidence.push({
            browser: browserName,
            browser_version: browserVersion,
            stage: spec.stage,
            delivery: target.delivery,
            exhaustive_cases: corpus.length,
            same_page_rounds: resourceContract.same_page_rounds,
            fresh_pages: resourceContract.fresh_pages,
            instances: freshPages,
            pass: true,
          });
        }
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await new Promise((done) => server.close(done));
}

console.log(
  JSON.stringify(
    {
      schema: 2,
      profile: "moi-runtime-f1-snapshot-browser-v2",
      pass: true,
      wt_sha: exportsEvidence.wt_sha,
      wasmtarget: exportsEvidence.wasmtarget,
      snapshot: exportsEvidence.snapshot,
      binaryen_jll: exportsEvidence.binaryen_jll,
      nodejs_24_jll: exportsEvidence.nodejs_24_jll,
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
      notebook_manifest_sha256:
        exportsEvidence.notebook_manifest_sha256,
      resource_contract: resourceContract,
      report_sha256: Object.fromEntries(
        stages.map(({ stage }) => [
          stage,
          {
            split: exportsEvidence[stage].split.report_sha256,
            portable: exportsEvidence[stage].portable.report_sha256,
          },
        ]),
      ),
      wasm_sha256: Object.fromEntries(
        stages.map(({ stage }) => [
          stage,
          {
            split: exportsEvidence[stage].split.wasm_sha256,
            portable: exportsEvidence[stage].portable.wasm_sha256,
          },
        ]),
      ),
      evidence,
    },
    null,
    2,
  ),
);
