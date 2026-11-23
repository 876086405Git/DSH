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
it('validates theme packs, referenced PNGs/fonts, and rejects undeclared extras', () => {
  const themeManifest = {
    schema: 1,
    id: 'sample',
    name: 'Paper & Ink',
    author: 'Synthetic author',
    license: 'CC0-1.0',
    source: 'https://example.org/synthetic',
    palette: { seed: '#A14732', tintHue: 74, tintChroma: 0.3, glowOpacity: 0 },
    surfaces: { preset: 'paper', backdropImage: 'paper-bg.png', backdropOpacity: 0.25, backdropRepeat: true },
    typography: { readingFont: 'reading.otf', readingLineHeight: 1.65 },
    components: { headerStyle: 'ghost', composerStyle: 'solidPaper', sendButtonStyle: 'ink', codeBlockStyle: 'outlined' },
    emptyState: { heroStyle: 'badge', suggestionsDisplay: 'collapsible' },
  };
  const otfFont = Buffer.from([0x4f, 0x54, 0x54, 0x4f, 0, 1, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4]);
  const good = zip([
    ['theme.json', Buffer.from(JSON.stringify(themeManifest))],
    ['paper-bg.png', png(4, 4)],
    ['reading.otf', otfFont],
  ]);
  expect(validatePack(good, metaFor(good, { kind: 'theme' }), 6)).toMatchObject({ files: 3 });

  const withExtra = zip([
    ['theme.json', Buffer.from(JSON.stringify(themeManifest))],
    ['paper-bg.png', png(4, 4)],
    ['reading.otf', otfFont],
    ['secret.txt', Buffer.from('nope')],
  ]);
  expect(() => validatePack(withExtra, metaFor(withExtra, { kind: 'theme' }), 6)).toThrow('theme_extra_file');

  const missingHeroImage = zip([
    ['theme.json', Buffer.from(JSON.stringify({ ...themeManifest, surfaces: { preset: 'paper' }, typography: {}, emptyState: { heroStyle: 'customImage' } }))],
  ]);
  expect(() => validatePack(missingHeroImage, metaFor(missingHeroImage, { kind: 'theme' }), 6)).toThrow('theme_schema');

  const unknownKey = zip([
    ['theme.json', Buffer.from(JSON.stringify({ ...themeManifest, surfaces: { preset: 'paper' }, typography: {}, extraField: true }))],
  ]);
  expect(() => validatePack(unknownKey, metaFor(unknownKey, { kind: 'theme' }), 6)).toThrow('theme_schema');
});
it('accepts the theme seam fields and rejects out-of-range values, unknown enums and mislabelled images', () => {
  const base = { schema: 1, id: 'sample', name: 'Seams', author: 'Synthetic author', license: 'CC0-1.0', source: 'https://example.org/synthetic' };
  const gifOf = (screen: number, frame: number) => Buffer.concat([Buffer.from('GIF89a'), Buffer.from([screen & 255, screen >> 8, screen & 255, screen >> 8, 0, 0, 0,
    0x21, 0xf9, 4, 0, 0, 0, 0, 0, 0x2c, 0, 0, 0, 0, frame & 255, frame >> 8, frame & 255, frame >> 8, 0, 2, 2, 0x4c, 0x01, 0, 0x3b])]);
  const gif = gifOf(1, 1);
  const webpOf = (w: number, h: number) => Buffer.concat([Buffer.from('RIFF'), Buffer.from([22, 0, 0, 0]), Buffer.from('WEBPVP8X'),
    Buffer.from([10, 0, 0, 0, 0, 0, 0, 0, (w - 1) & 255, ((w - 1) >> 8) & 255, 0, (h - 1) & 255, ((h - 1) >> 8) & 255, 0])]);
  const webp = webpOf(64, 64);
  const theme = (manifest: object, files: [string, Uint8Array][] = []) => {
    const bytes = zip([['theme.json', Buffer.from(JSON.stringify({ ...base, ...manifest }))], ...files]);
    return () => validatePack(bytes, metaFor(bytes, { kind: 'theme' }), 6);
  };
  expect(theme({
    palette: { seed: '#2B6A58', light: { link: '#1A5FB4', rule: '#802B6A58', patternInk: '#14322A' }, dark: { sendButton: '#7FC7B0', cardFill: '#CC1A2521', danger: '#FF6B6B', syntaxKeyword: '#E0A458', syntaxComment: '#997F8A80' } },
    surfaces: { preset: 'paper', pattern: 'grid', patternOpacity: 0.1, patternScale: 1.5, glowLayout: 'top', backdropImage: 'rain.gif', backdropBlur: 40, backdropAlign: 'bottom', backdropAnimate: false },
    typography: { readingLetterSpacing: 0.3, headingLetterSpacing: -0.5, headingWeight: 700, codeScale: 0.9 },
    shapes: { cornerStyle: 'bevel', bubbleCorners: 'tail', bubbleRadius: 20, cardRadius: 0, codeRadius: 6, composerRadius: 36, bubblePadH: 18, bubblePadV: 10 },
    components: {
      assistantStyle: 'quote', sendButtonStyle: 'outlined', sendButtonShape: 'square', codeHeaderStyle: 'plain', turnDivider: 'dashed', headingStyle: 'marker', bulletStyle: 'diamond', headerTitleFont: 'heading',
      userLabel: { zh: '我', en: 'Me' }, assistantLabel: { en: 'Reply' }, composerHint: { zh: '写点什么' }, assistantAvatar: 'bot.webp', userAvatar: 'me.png',
    },
    emptyState: { heroStyle: 'seal', heroGlyph: '😀a文b', heroScale: 1.4, greeting: { zh: '见字如面' }, subtitle: { zh: '慢慢写', en: 'Take your time' } },
  }, [['rain.gif', gif], ['bot.webp', webp], ['me.png', png(4, 4)]])()).toMatchObject({ files: 4 });

  for (const bad of [
    { surfaces: { patternScale: 3.5 } }, { surfaces: { pattern: 'stripes' } }, { surfaces: { backdropBlur: 41 } },
    { typography: { headingWeight: 650 } }, { shapes: { bubbleRadius: 37 } }, { components: { bulletStyle: 'star' } },
    { components: { userLabel: { zh: '字'.repeat(17) } } }, { components: { userLabel: { ja: 'わたし' } } }, { components: { composerHint: {} } },
    { emptyState: { heroStyle: 'seal' } }, { emptyState: { heroGlyph: '一二三四五' } }, { emptyState: { heroScale: 0.5 } },
    { palette: { light: { link: 'blue' } } }, { extends: 'paper' },
  ]) expect(theme(bad), JSON.stringify(bad)).toThrow('theme_schema');
  expect(theme({ surfaces: { backdropImage: 'photo.jpg' } }, [['photo.jpg', gif]])).toThrow('theme_asset_name');
  expect(theme({ surfaces: { backdropImage: 'rain.gif' } }, [['rain.gif', webp]])).toThrow('theme_image_header');
  expect(theme({ components: { userAvatar: 'me.webp' } }, [['me.webp', png(4, 4)]])).toThrow('theme_image_header');
  expect(theme({ components: { userAvatar: 'me.webp' } }, [['me.webp', webpOf(5000, 16)]])).toThrow('theme_image_size');
  // A first frame larger than the screen the GIF declares: the decoder grows the canvas to fit.
  expect(theme({ surfaces: { backdropImage: 'rain.gif' } }, [['rain.gif', gifOf(1, 8192)]])).toThrow('theme_image_size');
  expect(theme({ surfaces: { backdropImage: 'rain.gif' } }, [['rain.gif', Buffer.concat([Buffer.from('GIF89a'), Buffer.from([1, 0, 1, 0, 0, 0, 0, 0x3b])])]])).toThrow('theme_image_size');
  expect(theme({ emptyState: { heroStyle: 'customImage', heroImage: 'hero.png' } }, [['hero.png', gif]])).toThrow('png_');
});
