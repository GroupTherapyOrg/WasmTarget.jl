import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";

const [pidFile, julia] = process.argv.slice(2);
if (!pidFile || !julia) {
  throw new Error("usage: node jump_timeout_tree.mjs PID_FILE JULIA");
}

const leaf = spawn(julia, ["--startup-file=no", "-e", "sleep(600)"], {
  stdio: "ignore",
});
await writeFile(pidFile, JSON.stringify({
  julia: process.ppid,
  node: process.pid,
  leaf: leaf.pid,
}));

await new Promise(() => {});
