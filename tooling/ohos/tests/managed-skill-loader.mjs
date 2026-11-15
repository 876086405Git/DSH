// Reuse this import adaptation in the channel suite. Product code has no test
// switches; only unavailable OH modules and .ets extensions are replaced here.
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export async function prepareManagedSkillModules({ source, directory,
  fileIoUrl = new URL('./managed-skill-fixture.mjs', import.meta.url).href }) {
  const names = ['ManagedSkillCore', 'ManagedSkillInstaller', 'ManagedSkillService'];
  for (const name of names) {
    let text = await fs.readFile(path.join(source, name + '.ets'), 'utf8');
    for (const imported of names) text = text.replaceAll(`from './${imported}'`, `from './${imported}.mts'`);
    if (name === 'ManagedSkillInstaller') {
      text = text.replace("import fs from '@ohos.file.fs';", `import { fileIo as fs } from '${fileIoUrl}';`)
        .replace("import util from '@ohos.util';", `import { util } from '${fileIoUrl}';`)
        .replace("import { BusinessError } from '@ohos.base';", '')
        .replace('import { ManagedSkillStorage,', 'import { type ManagedSkillStorage,');
    }
    await fs.writeFile(path.join(directory, name + '.mts'), text);
  }
  return {
    coreUrl: pathToFileURL(path.join(directory, 'ManagedSkillCore.mts')).href,
    installerUrl: pathToFileURL(path.join(directory, 'ManagedSkillInstaller.mts')).href,
    serviceUrl: pathToFileURL(path.join(directory, 'ManagedSkillService.mts')).href,
  };
}
