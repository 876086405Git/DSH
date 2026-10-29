import { runCheck } from "../lib/index.js";

const cases = [
  ["不兼容包", "E:/kaifa/DSH-KAIFA/dsh-checkup/test/fixtures/incompatible"],
  ["兼容包", "E:/kaifa/DSH-KAIFA/dsh-checkup/test/fixtures/compatible"],
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
