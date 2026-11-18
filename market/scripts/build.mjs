import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkDirectory } from './check.mjs';
import { digest, makeIndex } from './core.mjs';
import semver from 'semver';
import { ohosSummary } from './ohos-scan.mjs';
export function build(rows, policy, now = new Date().toISOString()) {
  if (!Array.isArray(policy.officialPackages) || !policy.blockedVersions || typeof policy.blockedVersions !== 'object')
    throw new Error('invalid-maintainer-policy');
  const plugins = {};
  for (const { entry, report } of rows) {
    if (
      report.status !== 'passed' ||
      report.denials.length ||
      report.entryHash !== digest(entry) ||
      report.version !== entry.version ||
      report.name !== entry.name
    )
      throw new Error(`unapproved:${entry.name}`);
    const blockedVersions = policy.blockedVersions[entry.name] ?? [];
    if (!Array.isArray(blockedVersions) || blockedVersions.some((v) => semver.valid(v) !== v))
      throw new Error('invalid-blocked-versions');
    if (blockedVersions.includes(entry.version)) throw new Error(`blocked-version:${entry.name}@${entry.version}`);
    if (Object.hasOwn(plugins, entry.name)) throw new Error('duplicate-package');
    plugins[entry.name] = {
      version: entry.version,
      tier: policy.officialPackages.includes(entry.name) ? 'official' : 'community',
      title: entry.title,
      summary: entry.summary,
      screenshots: entry.screenshots ?? [],
      dshGo: report.dshGo,
      risk: report.risk,
      integrity: report.integrity,
      checkedAt: report.checkedAt,
      blockedVersions,
      platforms: { ohos: ohosSummary(report.platforms.ohos) },
    };
  }
  return { index: makeIndex(rows), sidecar: { schema: 1, generatedAt: now, plugins } };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    // Always re-download and re-check. Never consume author-supplied audit reports.
    const rows = await checkDirectory(process.argv[2] ?? 'plugins');
    await mkdir('reports', { recursive: true });
    await writeFile(
      'reports/build-audit.json',
      JSON.stringify({ schema: 1, results: rows.map((r) => r.report) }, null, 2) + '\n',
    );
    const policy = JSON.parse(await readFile('policy.json', 'utf8'));
    const output = build(rows, policy);
    await mkdir('dist', { recursive: true });
    await writeFile('dist/index.json', JSON.stringify(output.index, null, 2) + '\n');
    await writeFile('dist/dsh-go.json', JSON.stringify(output.sidecar, null, 2) + '\n');
    await writeFile(
      'dist/audit.json',
      JSON.stringify({ schema: 1, results: rows.map((r) => r.report) }, null, 2) + '\n',
    );
    console.log(`Built ${rows.length} pinned plugins; official format 1 validator passed.`);
  } catch (e) {
    console.error(e.message);
    process.exitCode = 1;
  }
}
