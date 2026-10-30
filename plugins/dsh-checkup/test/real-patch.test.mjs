import { copyFileSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { writeProfileConfig } from "../lib/index.js";
import { DESKTOP_PROFILE_PATCH, loadYaml } from "./_paths.mjs";

const yaml = loadYaml();

const real = DESKTOP_PROFILE_PATCH;
const before = yaml.parse(readFileSync(real, "utf8"));
const dir = mkdtempSync(join(tmpdir(), "guard-real-"));
const copy = join(dir, "cordis.patch.yml");
copyFileSync(real, copy);

const config = {
  preflightEnabled: true, blockOnWarn: false,
  registries: ["https://registry.npmmirror.com", "https://registry.npmjs.org"],
  lookupTimeoutMs: 8000, lookupAttempts: 2, knownBad: [],
};
const result = await writeProfileConfig(copy, config);
const after = yaml.parse(readFileSync(copy, "utf8"));

// 真实 profile 里可能已经存在 checkup 条目（面板保存过配置）：
// 那种情况下这里是「更新」而不是「追加」，条目数不变 —— 两种都算正常。
const ownId = "checkup";
const wasPresent = before.some((entry) => entry.id === ownId);
let diff = 0;
for (let i = 0; i < before.length; i++) {
  const isOwn = before[i].id === ownId;
  if (isOwn) continue; // 自己那条本来就该被改写
  if (JSON.stringify(before[i]) !== JSON.stringify(after[i])) {
    diff += 1;
    console.log("CHANGED at index", i, before[i].id || "(insert)");
  }
}
const own = after.find((entry) => entry.id === ownId);
const last = after[after.length - 1];
const expectLength = wasPresent ? before.length : before.length + 1;
console.log("写入:", result, "| 条目数:", before.length, "->", after.length, "| 原本已存在:", wasPresent);
console.log("其他条目改动数:", diff);
console.log("checkup config:", JSON.stringify(own && own.config));
console.log("末条 id:", last.id, "| name:", last.name);

await writeProfileConfig(copy, config);
const again = yaml.parse(readFileSync(copy, "utf8"));
console.log("二次保存条目数:", again.length);

rmSync(dir, { recursive: true, force: true });
const pass =
  diff === 0 &&
  after.length === expectLength &&
  own &&
  own.name === "dsh-checkup" &&
  own.config.lookupTimeoutMs === 8000 &&
  again.length === after.length;
console.log("\nRESULT:", pass ? "PASS" : "FAIL");
