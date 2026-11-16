import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { prepareLinuxImages } from '../../../../runtime/ohos/linux/prepare-images.mjs';
const [guest, archive, output] = process.argv.slice(2);
const build = JSON.parse(await readFile(join(guest, 'BUILD.json'), 'utf8'));
const asset = name => ({ path: join(guest, 'image', name + '.gz'),
  ...build.assets[name + '.gz'], expandedBytes: build.assets[name].bytes,
  expandedSha256: build.assets[name].sha256 });
const events = [];
const images = await prepareLinuxImages({ directory: output,
  bootstrap: asset('bootstrap.ext4'), empty: asset('empty.ext4'),
  archive: { path: archive, bytes: build.archiveOriginalBytes, sha256: build.archiveSha256 },
  onProgress: event => { if (event.done === event.total || event.done % (1024 * 1024) === 0) events.push(event); },
});
const config = join(images.directory, 'install.cfg');
await writeFile(config, JSON.stringify({ version: 1, machine: 'riscv64', memory_size: 256,
  bios: join(guest, 'image/bbl64.bin'), kernel: join(guest, 'image/kernel-riscv64.bin'),
  cmdline: 'console=hvc0 root=/dev/vda ro init=/sbin/dsh-init',
  drive0: { file: images.bootstrap, readOnly: true },
  drive1: { file: images.archive, readOnly: true }, drive2: { file: images.target },
}) + '\n');
await writeFile(join(output, 'PREPARED.json'), JSON.stringify({ ...images, config, events }, null, 2) + '\n');
console.log(config);
