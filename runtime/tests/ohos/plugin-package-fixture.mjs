export const toolSource = version => `
export const name = 'ohos-installed-tool';
export const inject = ['tools'];
export function apply(ctx) {
  ctx.tools.register({
    name: 'ohos_installed_echo', description: 'Installation fixture echo',
    parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] },
    output: { schema: { type: 'object', properties: { text: { type: 'string' }, version: { type: 'string' } }, required: ['text', 'version'] },
      render: (args, value) => [{ type: 'text', text: JSON.stringify(value) }] },
    execute: async args => ({ text: args.text, version: '${version}' }),
  });
}
`;
export function tarFile(path, content) {
  const body = Buffer.from(content), header = Buffer.alloc(512);
  header.write('package/' + path, 0, 100);
  for (const [offset, size, value] of [[100, 8, 0o644], [108, 8, 0], [116, 8, 0], [124, 12, body.length], [136, 12, 0]]) {
    header.write(value.toString(8).padStart(size - 1, '0') + '\0', offset, size);
  }
  header.fill(32, 148, 156); header.write('0', 156); header.write('ustar\0', 257); header.write('00', 263);
  header.write(header.reduce((a, b) => a + b, 0).toString(8).padStart(6, '0') + '\0 ', 148, 8);
  return Buffer.concat([header, body, Buffer.alloc((512 - body.length % 512) % 512)]);
}

