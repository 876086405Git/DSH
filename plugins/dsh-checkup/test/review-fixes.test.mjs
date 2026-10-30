// 第二轮代码审查修复的回归测试（C1 / C2 / M1 / M2 / 专家解析 / symlink）
//
// 这些用例都直接钉住「审查报告里指出的那个具体缺陷」，
// 每条断言都在修复前能复现失败（反向插桩见各段注释）。
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { DESKTOP_PROFILE_MODULES } from "./_paths.mjs";

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra === undefined ? "" : " -> " + JSON.stringify(extra)}`);
  }
};

// ── 准备隔离的 HOME ───────────────────────────────────────────────────────
const tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "checkup-review-"));
const profileDir = path.join(tmpHome, "profiles", "desktop");
fs.mkdirSync(profileDir, { recursive: true });
process.env.DSH_HOME = tmpHome;

const patchFile = path.join(profileDir, "cordis.patch.yml");
const patchText = [
  "# 用户手写注释，必须保留",
  "- insert:",
  "    - id: mcp-cad   # 行尾注释：旧实现会让整个条目消失",
  '      name: "@deepseek-ai/dsh-mcp-client"',
  "      config: |",
  "        transport: stdio",
  "        serverName: cad",
  "        command: C:\\tools\\uvx.exe   # 命令注释",
  "        args:",
  "          - --offline",
  "          - --from",
  "    - id: preset-wbexpert-demo",
  '      name: "@deepseek-ai/dsh-agent-preset"',
  "      config:",
  "        id: demo",
  "        name: 演示专家",
  "        plugins:",
  "          - id: persona",
  '            name: "@deepseek-ai/dsh-persona"',
  "            config:",
  "              prefix: |",
  "                你是一位资深代码审查专家，负责在缺陷进入生产前拦下它们。",
  "                工作原则：先读代码再下结论，每条意见都要说清为什么。",
  "          - id: group",
  '            name: "cordis:group"',
  "",
  "- id: checkup",
  "  name: dsh-checkup",
  "  config: {}",
  "",
].join("\n");
fs.writeFileSync(patchFile, patchText, "utf8");

const mod = await import("../lib/index.js");
const { collectArmory, readMcpEntries, readExpertPresets, writeProfileConfig, normalizeSettings } = mod;

console.log("\n[M1] MCP 解析要容忍行尾注释（旧实现整条丢失）");
{
  const entries = await readMcpEntries();
  ok("解析出 1 个 MCP 条目", entries.length === 1, entries.length);
  const cad = entries[0] || { config: {} };
  ok("serverName = cad", cad.config.serverName === "cad", cad.config.serverName);
  ok("command 不含注释", String(cad.config.command).trim() === "C:\\tools\\uvx.exe", cad.config.command);
  ok("args 解析出 2 项", Array.isArray(cad.config.args) && cad.config.args.length === 2, cad.config.args);
}

console.log("\n[M1 兜底] YAML 非法时退回行扫描，不整条丢");
{
  const broken = patchText + "\n  bad: [unclosed\n";
  fs.writeFileSync(patchFile, broken, "utf8");
  const entries = await readMcpEntries();
  ok("YAML 坏了仍能兜底解析出条目", entries.length >= 1, entries.length);
  fs.writeFileSync(patchFile, patchText, "utf8");
}

console.log("\n[专家] persona 嵌在 plugins[].config.prefix，不能被读成空");
{
  const experts = await readExpertPresets();
  ok("解析出 1 个专家", experts.length === 1, experts.length);
  const one = experts[0] || {};
  ok("id 正确", one.id === "preset-wbexpert-demo", one.id);
  ok("hasPersona = true（旧实现按行切块会读成 false）", one.hasPersona === true, one.hasPersona);
  ok("externalRefs 过滤掉 cordis:group", Array.isArray(one.externalRefs) && one.externalRefs.length === 0, one.externalRefs);
}

console.log("\n[C2] 配置写入必须覆盖全部字段");
{
  const config = normalizeSettings(
    {
      preflightEnabled: true,
      blockOnWarn: false,
      registries: ["https://registry.npmmirror.com"],
      lookupTimeoutMs: 8000,
      lookupAttempts: 2,
      knownBad: [],
      maliciousPackages: ["evil-pkg"],
      levelOverrides: { "runtime-version": "pass" },
      confirmTimeoutMs: 120000,
    },
    {},
  );
  await writeProfileConfig(patchFile, config);
  const written = fs.readFileSync(patchFile, "utf8");
  ok("文件含 levelOverrides", written.includes("levelOverrides"), written.slice(0, 0));
  ok("文件含 maliciousPackages", written.includes("maliciousPackages"));
  ok("文件含 confirmTimeoutMs", written.includes("confirmTimeoutMs"));
  ok("写前留了备份", fs.existsSync(`${patchFile}.checkup.bak`));
  // 回读
  const saved = /config: (\{.*\})/.exec(written);
  const parsed = saved ? JSON.parse(saved[1]) : {};
  ok("levelOverrides 值正确", parsed.levelOverrides && parsed.levelOverrides["runtime-version"] === "pass", parsed.levelOverrides);
  ok("maliciousPackages 值正确", Array.isArray(parsed.maliciousPackages) && parsed.maliciousPackages[0] === "evil-pkg", parsed.maliciousPackages);
  fs.writeFileSync(patchFile, patchText, "utf8");
}

console.log("\n[M2] 条目行带注释/引号时也能认出来，不追加重复条目");
{
  const variant = patchText.replace("- id: checkup", '- id: "checkup"   # 引号 + 注释');
  fs.writeFileSync(patchFile, variant, "utf8");
  const before = (fs.readFileSync(patchFile, "utf8").match(/name: dsh-checkup/g) || []).length;
  await writeProfileConfig(patchFile, normalizeSettings({}, {}));
  const after = fs.readFileSync(patchFile, "utf8");
  const count = (after.match(/name: dsh-checkup/g) || []).length;
  ok("没有追加第二条 checkup", count === before, { before, after: count });
  fs.writeFileSync(patchFile, patchText, "utf8");
}

console.log("\n[C1] 隔离区路径校验：穿越与同前缀兄弟目录都必须拒绝");
{
  const { InstallSentinel } = await import("../lib/guard.js");
  const quarantine = path.join(tmpHome, "quarantine");
  const outside = path.join(tmpHome, "skills");
  const sibling = path.join(tmpHome, "quarantine-evil");
  for (const dir of [quarantine, outside, sibling]) fs.mkdirSync(dir, { recursive: true });
  fs.mkdirSync(path.join(quarantine, "evil-skill-123"), { recursive: true });
  fs.mkdirSync(path.join(outside, "keep-me"), { recursive: true });
  fs.mkdirSync(path.join(sibling, "keep-too"), { recursive: true });

  const sentinel = new InstallSentinel({
    skillsRoots: [outside],
    patchFile,
    quarantineDir: quarantine,
    checkSkillDir: async () => ({ ok: true, checks: [] }),
    checkMcpConfig: async () => ({ ok: true, checks: [] }),
  });

  const cases = [
    ["向上穿越到 skills", path.join(quarantine, "..", "skills")],
    ["同前缀兄弟目录", sibling],
    ["隔离区根本身", quarantine],
    ["绝对无关路径", "C:\\Windows"],
  ];
  for (const [label, target] of cases) {
    let rejected = false;
    try {
      await sentinel.releaseQuarantined(target, "delete");
    } catch {
      rejected = true;
    }
    ok(`${label} → 拒绝`, rejected);
  }
  ok("越界目录都没被删", fs.existsSync(path.join(outside, "keep-me")) && fs.existsSync(path.join(sibling, "keep-too")));

  // 正常项必须仍可操作（防「保护过度」）
  let released = null;
  try {
    released = await sentinel.releaseQuarantined(path.join(quarantine, "evil-skill-123"), "delete");
  } catch (error) {
    released = { error: String(error) };
  }
  ok("隔离区内正常项可删除", released && released.action === "deleted", released);
  sentinel.stop();
}

console.log("\n[symlink] 采集必须识别 pnpm 的 symlink 包（真实 profile）");
{
  const rawProfile = DESKTOP_PROFILE_MODULES;
  let hasSymlinkPkg = false;
  try {
    for (const scope of fs.readdirSync(rawProfile, { withFileTypes: true })) {
      if (!scope.isDirectory()) continue;
      const sub = path.join(rawProfile, scope.name);
      if (!scope.name.startsWith("@")) continue;
      for (const entry of fs.readdirSync(sub, { withFileTypes: true })) {
        if (entry.isSymbolicLink()) hasSymlinkPkg = true;
      }
    }
  } catch {}
  if (!hasSymlinkPkg) {
    console.log("  skip 本机没有 symlink 包，跳过（不判失败）");
  } else {
    const items = await collectArmory();
    const ghosts = items.plugins.filter((p) => p.inNodeModules === false);
    ok("真实环境里没有误报「实体缺失」", ghosts.length === 0, ghosts.map((g) => g.name));
  }
}

// ── 清理 ─────────────────────────────────────────────────────────────────
try {
  fs.rmSync(tmpHome, { recursive: true, force: true });
} catch {}

console.log("\n==============================");
console.log(failures === 0 ? "ALL PASS" : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
