import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const expected = '5864d63ca1b37272fe72b91205b0c18efc4ac0ce36cca178f59c50b33b14a7b7';
if (process.argv.length !== 3) {
  throw new Error('Usage: node tool/make_chat_read_probe.mjs /path/to/zz_bench_heavy_card_r183_test.dart');
}
const input = await readFile(process.argv[2]);
const digest = createHash('sha256').update(input).digest('hex');
if (digest !== expected) throw new Error('The supplied heavy benchmark SHA-256 does not match the W7 input.');
const original = input.toString('utf8');
const suffix = await readFile(new URL('./chat_read_probe.dart.inc', import.meta.url), 'utf8');

function once(text, marker, replacement) {
  if (text.split(marker).length !== 2) throw new Error('Expected one source marker: ' + marker);
  return text.replace(marker, replacement);
}

if (original.split('\nvoid main() {\n').length !== 2) throw new Error('Expected exactly one original main.');
// Register after the original hooks, reusing their lazily initialized PNG.
const firstTest = "  test('codec / intake breakdown (synchronous, off-engine)', () async {";
let generated = once(original, firstTest, '  _registerChatReadProbes(() => card);\n\n' + firstTest);
// Stopwatch, 1 ms Timer and gap formula stay unchanged. Printing is after cancellation.
const printGap = "  // ignore: avoid_print\n  print('BENCHGAP ";
const printUs = "  // ignore: avoid_print, prefer_interpolation_to_compose_strings\n" +
  "  print('BENCHUS ' + jsonEncode({'name': name, 'totalUs': sw.elapsedMicroseconds, 'gapUs': worst.inMicroseconds}));\n";
generated = once(generated, printGap, printUs + printGap) + '\n' + suffix;
const output = new URL('./zz_bench_chat_reads_test.dart', import.meta.url);
await writeFile(output, generated, { flag: 'wx' });
process.stdout.write(JSON.stringify({
  sourceSha256: digest,
  output: fileURLToPath(output),
  generatedSha256: createHash('sha256').update(generated).digest('hex'),
  changes: ['one registration call', 'one BENCHUS row after timer cancellation', 'appended probe source'],
}) + '\n');
