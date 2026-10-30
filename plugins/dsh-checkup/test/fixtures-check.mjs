import { join } from "node:path";
import { runCheck } from "../lib/index.js";
import { REPO_ROOT } from "./_paths.mjs";

const cases = [
  ["不兼容包", join(REPO_ROOT, "test", "fixtures", "incompatible")],
  ["兼容包", join(REPO_ROOT, "test", "fixtures", "compatible")],
];

for (const [label, spec] of cases) {
  const report = await runCheck(spec);
  console.log("\n===== " + label + " :: " + spec + " =====");
  console.log("结论: ok=" + report.ok + " blocked=" + report.blocked + " warned=" + report.warned + " passed=" + report.passed);
  for (const c of report.checks) {
    console.log("  [" + c.level + "] " + c.title);
    if (c.detail) console.log("        " + c.detail);
    if (c.hint) console.log("        建议: " + c.hint);
  }
}
