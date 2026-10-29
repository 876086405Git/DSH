import { probeEnvironment } from "../lib/index.js";
import { resolveManifest } from "../lib/index.js";
import { checkCandidate } from "../lib/rules.js";

const env = await probeEnvironment();
console.log("dshVersion:", env.dshVersion, "| known:", env.dshVersionKnown);
console.log("client packages:", env.availableClientPackages.length);
console.log("has dsh-api-remotes:", env.availableClientPackages.includes("@deepseek-ai/dsh-api-remotes"));
console.log("bundles:", env.profileBundles.length);

const r = await resolveManifest("dsh-armory@2.4.3", { attempts: 3, timeoutMs: 8000 });
if (r.manifest) {
  const report = checkCandidate({ spec: "dsh-armory@2.4.3", manifest: r.manifest, env });
  console.log("\ndsh-armory@2.4.3 -> ok=" + report.ok + " blocked=" + report.blocked + " warned=" + report.warned);
  for (const c of report.checks) console.log("  [" + c.level + "] " + c.title + " :: " + (c.detail || "").slice(0, 120));
} else {
  console.log("registry skip:", r.reason);
}
