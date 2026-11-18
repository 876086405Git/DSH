import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { fixture, name, executeTool } from './plugin-package-harness.mjs';

// Real npm 11.9.0 pack --ignore-scripts archives; only locale/en.json gains EF BB BF.
// All exports and remaining package bytes match. Archive digests bind the fixture.
const localePlainArchive = Buffer.from('H4sIAAAAAAAC/+1Y32vbMBDOs/+KQ3twAo4rNz8GLh0M1oeNbYXtsYSiypfEqS15ktw5BP/vQ7aTxmmhY7SBDH8vtk+f7iTwd3dSxvg9W+BZIjlL8AyFv9JS9F4VlNLpeAzP2S2C8wn0RpMpDYLplI6hR4NzGpxDj/aOgFwbpnqUvsImKaWwe54INiRFw0gIG2JikyAJgVz/FhhB/UdAbfWARKi5ijMTS/GEtD9Wlk6vw6kga/TfPN9A/S/qfxLQQ/0Hk3Gn/+Po3wEggqWV8OVS6qG0wh6u9PAuF5GVvmU8oNKN8AOf+rS2mnVWzUtllG+ZWGRSGW0zigMAQHzL8M9iEWHhpytd0ay99c/VpJZlx2vXppp5YHMAyip8pJePoZsdbL8BSMYMtwTCpYpi7Vff/jpNSMUoH/20s13KRDxHbWDOkuSO8ftWynNON+Vt9f/j6uOnb1d+Gr1BjBf0T6fvD/VPO/0fCe+gVcib38FxvuKCJVurbREiZhhwKYySid9V+P+t/u/S89H1HwSj8ZP6H9Cg0/8x4NT12ipbG7CNAFyCWzUCsdCGJQlGQyNl4l60qbFYITdwCTeuHdbubEeY54Lbuggsy5J1n5tiUFVgbgq/4voKF7E2qPp1YbZhwzrq7S7qLfKldL39QhuC+7keZpX/eVyYXCHUzMpVxhRL0aDSIWzANijW8Z1dq+tBpmSGysRYj2Jh9ljaqFgsXCih9EDhrzxWGIV2f1gYd1Y3BgAyN1lezdN8iSn79zgeNG3VXy/CA7eZ8rgeAIUiQhVCn6mF9uCBJTkO4PID3OzcNrPrlXz5ef3drwPF83W/4Zc7j1ggzw2GwPRacLBerbf+difW4NvXvQ24VVvoQjmwPsrBhdMdA08p/x/2w8e8/7F3PQf3P6PJtMv/x8DNhsRCozIktK8RCUl9AGxnf+I1h8Tnz4jlrJx1WurQoUOHU8IfMAlcNAAaAAA=', 'base64'); // sha256 297463852e7b872623f3ea0d464e9321975938ad176aed4178ac96d1b0438907
const localeBomArchive = Buffer.from('H4sIAAAAAAAC/+1Y3WrbMBTOtZ/ioF04AceVm5+BSweD9WJjW2G7LKGo9kni1JY8Sd4cgp9sF3ukvcKQ5aRxW+gYbSDD343to0/nSODvnCPlLLplCzxJRcRSPEHur5TgvWcFpXQ6HsNjdoNgRKE3mkxpEEyndAw9GpxSOoUe7R0AhdJM9ih9hk1SSmH3PBL8/vlrQzLUjISwITrRKZIQyOUPjjHYnwKs1QMSo4pkkutE8Aek/bGqcnodjgJ5o//m+QLqf1L/k+CB/oPJ+LTT/yGwcQAIZ1mterEUaiiMqocrNbwpeGx0bxjfUapG9YFPfWqtep3X8zIRF1smlrmQWpl04gAAEN8w/JOEx1j62UrVNGNv/XOW1LLseO3aZJn3bA5AVYeP1fIudLOD7TcAyZmODIFEQsaJ8utvf52lpGZUd37aqS5jPJmj0jBnaXrDottWvnOON99t9f/l4u27Txd+Fr9AjCf0T6ev7+ufdvo/EF5Bq4o3v4PjfMQFS7dW0x/ETDOIBNdSpH5X3v+3+r9LzwfXfxCMxg/qf0CDTv+HgGPrtVG20mAaATgHt24EEq40S1OMh1qI1D1rUxO+wkjDOVy5Zli5sx1hXvDI1EVgeZ6u+5EuB3UFjnTp11xf4iJRGmXfFmYTNrRRr3dRrzFaCtfbL7QhuO/tMKv9z5NSFxLBMmtXOZMsQ41ShbAB06AYxzdmra4HuRQ5Sp2gHcVS77GUlglfuFBB5YHEb0UiMQ7N/rDU7sw2BgCi0HlRz1PREjP273E8aNqqv16EB24z5W49ABJ5jDKEPpML5cF3lhY4gPM3cLVz28y2K/nw9fKzbwMl83W/4Vc7j1hiVGgMgak1j8B4Nd76250Yg29e9zbg1m2hC9XA+KgGZ053Bjym/H+/Hz7k/U9w+uD+ZzTp7n8OgqsNSbhCqUloXmMSEnsAbGd/4jWHxMfPiNWsmnVa6tChQ4djwh/qjYI9ABoAAA==', 'base64'); // sha256 6b017ca908425e024a9d56c3139b19a50ab1386671546dd4746e0d082af4a26a

for (const [label, archive] of [['plain', localePlainArchive], ['single BOM', localeBomArchive]]) {
  test(`real npm ${label} locale retains metadata through actual manager`, { timeout: 30000 }, async t => {
    const f = await fixture(t, { '1.0.0': { archive, manifest: { description: 'manifest fallback description', exports: { '.': './index.mjs', './package.json': './package.json', './locale/en.json': './locale/en.json' } } } }, { hmr: true });
    const result = await f.invoke('installBundle', `${name}@1.0.0`, { registry: f.registry, enabled: true });
    assert.equal(result.application, 'applied', JSON.stringify(result));
    const bundle = (await f.invoke('listBundles')).find(row => row.name === name);
    for (const meta of [bundle.meta, ...bundle.rows.map(row => row.meta)]) {
      assert.equal(meta?.error, undefined, JSON.stringify(meta));
      assert.equal(meta.title.en, 'Owned locale title');
      assert.equal(meta.description.en, 'Owned locale description');
    }
    await executeTool(f.ctx, '1.0.0');
  });
}

test('metadata accepts one leading BOM but retains locale JSON and field rejections', async t => {
  const { mkdtemp, mkdir, writeFile, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { readPluginMeta } = await import(pathToFileURL(join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')));
  const dir = await mkdtemp(join(tmpdir(), 'owned-locale-boundary-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const pkg = join(dir, 'node_modules', 'owned-locale-boundary');
  await mkdir(join(pkg, 'locale'), { recursive: true });
  await writeFile(join(pkg, 'package.json'), JSON.stringify({name:'owned-locale-boundary',version:'1.0.0',exports:{'./package.json':'./package.json','./locale/en.json':'./locale/en.json'}}));
  const parent = pathToFileURL(join(dir, 'root.mjs')).href;
  for (const text of ['\ufeff\ufeff{}', ' \ufeff{}', '{bad', '[]', '{"meta":[]}', '{"meta":{"title":3}}']) {
    await writeFile(join(pkg, 'locale/en.json'), text);
    assert.equal(typeof readPluginMeta('owned-locale-boundary', parent)?.error, 'string', JSON.stringify(text));
    if (['\ufeff\ufeff{}', ' \ufeff{}', '{bad'].includes(text)) {
      const require = createRequire(parent);
      const id = require.resolve('owned-locale-boundary/locale/en.json');
      delete require.cache[id];
      assert.throws(() => require(id), SyntaxError, 'actual Node JSON loader also rejects malformed BOM/JSON');
    }
  }
});
