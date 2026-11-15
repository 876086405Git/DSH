import { readFileSync } from 'node:fs';
import { deflateRawSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { WorkshopArchive, inflate, nameAlias, strictJson } from '../src/workshop-archive';
import { validatePack, validatePet } from '../src/workshop-pack';
import { validatePng } from '../src/workshop-png';
import { chunk, companion, metaFor, pet, petManifest, png, zip } from './workshop-fixtures';
const fixture = (name: string) => JSON.parse(readFileSync(new URL(`../../../app/test/pets/fixtures/${name}.json`, import.meta.url), 'utf8'));
const accepted = (f: () => unknown) => { try { f(); return true; } catch { return false; } };

describe('same synthetic fixture corpus as current App validators', () => {
  const small = fixture('pet-validation-small');
  for (const c of small.json) it(`strict JSON ${c.name}`, () => expect(accepted(() => strictJson(Buffer.from(c.raw)))).toBe(c.ciAccepted));
  for (const c of small.archive) it(`ZIP ${c.name}`, () => {
    const check = () => { const archive = new WorkshopArchive(Buffer.from(c.zip, 'base64'), 256); for (const name of archive.files.keys()) archive.read(name, 3); };
    expect(accepted(check)).toBe(c.readValid);
  });
  for (const c of small.png) it(`PNG EOF ${c.name}`, () => expect(accepted(() => validatePng(Buffer.from(c.png, 'base64')))).toBe(c.valid));
  for (const c of fixture('pet-png-v2').cases) it(`PNG chunks/decode ${c.name}`, () => expect(accepted(() => validatePng(Buffer.from(c.base64, 'base64')))).toBe(c.accepted));
  for (const c of fixture('pet-pack-local-v1').cases) it(`App import semantics ${c.name}`, () => {
    // This corpus tests parser/overlay semantics, not upload provenance. Supply
    // the workshop's mandatory known metadata without changing geometry.
    const pack = { ...c.pack, id: 'sample', author: 'Synthetic author', license: 'CC0-1.0', source: 'https://example.org/synthetic' };
    const bytes = zip([['pack.json', Buffer.from(JSON.stringify(pack))], ['cat.png', png(16, 16)]]);
    expect(accepted(() => validatePet(bytes, metaFor(bytes)))).toBe(c.appImportValid);
  });
});

it('uses NFC then full Unicode 15 casefold, including Hangul and expanded folds', () => {
  expect(nameAlias('Straße.png')).toBe(nameAlias('STRASSE.PNG'));
  expect(nameAlias('É.png')).toBe(nameAlias('E\u0301.PNG'));
  expect(nameAlias('\u1100\u1161.png')).toBe(nameAlias('가.PNG'));
  expect(nameAlias('Σς.png')).toBe(nameAlias('σσ.PNG'));
  expect(() => new WorkshopArchive(zip([['É.png', Buffer.from('a')], ['e\u0301.PNG', Buffer.from('b')]]), 256)).toThrow('archive_duplicate');
});
it('validates actual deflate EOF and cap, not a declared ZIP size', () => {
  const compressed = deflateRawSync(Buffer.alloc(100000));
  expect(() => inflate(compressed, 10)).toThrow();
  expect(() => inflate(Buffer.concat([deflateRawSync(Buffer.from('abc')), Buffer.from('extra')]), 3)).toThrow('inflate_trailing');
  expect(() => inflate(deflateRawSync(Buffer.from('abc')).subarray(0, 2), 3)).toThrow('inflate_invalid');
});
it('reconstructs every RGBA pixel and validates the pack references/geometry', () => {
  expect(validatePng(png(7, 3))).toMatchObject({ pixels: 21, rgbaSum: 21 * 510 });
  const bytes = pet(); expect(validatePack(bytes, metaFor(bytes), 6)).toMatchObject({ sheets: 1, files: 2 });
  const pack = petManifest(); pack.animations.idle.frames[0]!.i = 1;
  const bad = pet(pack); expect(() => validatePet(bad, metaFor(bad))).toThrow('sheet_frame_bounds');
  expect(() => validatePet(bytes, { ...metaFor(bytes), author: 'someone else' })).toThrow('pack_metadata_mismatch');
});
it('rejects runtime, unsafe/missing references and future/unknown moc formats', () => {
  const good = companion(); expect(validatePack(good, metaFor(good, { kind: 'companion' }), 6)).toMatchObject({ mocVersions: [6] });
  for (const options of [{ runtime: true }, { reference: '../sample.moc3' }, { reference: 'https://example.org/a.moc3' }, { version: 7 }, { version: 0 }]) {
    const bytes = companion(options); expect(() => validatePack(bytes, metaFor(bytes, { kind: 'companion' }), 6)).toThrow();
  }
});
it('takes Live2D-sized textures by their header: 4096 and 8192 a side pass, larger or not a PNG fails', () => {
  const texture = (side: number) => {
    const head = Buffer.alloc(13); head.writeUInt32BE(side); head.writeUInt32BE(side, 4); head[8] = 8; head[9] = 6;
    return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', head), chunk('IEND', Buffer.alloc(0))]);
  };
  for (const side of [4096, 8192]) {
    const bytes = companion({ texture: texture(side) });
    expect(validatePack(bytes, metaFor(bytes, { kind: 'companion' }), 6)).toMatchObject({ mocVersions: [6] });
  }
  const huge = companion({ texture: texture(8193) });
  expect(() => validatePack(huge, metaFor(huge, { kind: 'companion' }), 6)).toThrow('png_decoded_size');
  const jpegNamedPng = companion({ texture: Buffer.alloc(64, 0xff) });
  expect(() => validatePack(jpegNamedPng, metaFor(jpegNamedPng, { kind: 'companion' }), 6)).toThrow('png_header');
});
it('refuses hidden extras instead of publishing local secrets or settings', () => {
  const bytes = pet(petManifest(), [['private.json', Buffer.from('{"synthetic":"not-for-publication"}')]]);
  expect(() => validatePet(bytes, metaFor(bytes))).toThrow('pet_extra_file');
});
it('accepts ordinary empty directories but rejects hidden directory data or a runtime tree', () => {
  expect(new WorkshopArchive(zip([['character/', Buffer.alloc(0)]]), 1000).directories).toEqual(new Set(['character/']));
  expect(() => new WorkshopArchive(zip([['character/', Buffer.from('unexpected directory content')]]), 1000)).toThrow('archive_directory_payload');
  const manifest = petManifest(), wrapped = zip([['sample/', Buffer.alloc(0)], ['sample/pack.json', Buffer.from(JSON.stringify(manifest))], ['sample/idle.png', png()]]);
  expect(validatePet(wrapped, metaFor(wrapped))).toMatchObject({ files: 2 });
});
