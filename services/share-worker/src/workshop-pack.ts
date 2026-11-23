import { PET_LIMITS, WORKSHOP_VALIDATOR_PROFILE } from './generated/workshop-data';
import { record } from './pet-catalog';
import { WorkshopArchive, nameAlias, strictJson } from './workshop-archive';
import { encoder, finite, MEMBER_CAP, requireWorkshop as need, type SubmissionMeta, whole } from './workshop-common';
import { validatePng, validateTexture } from './workshop-png';

export const VALIDATOR_VERSION = `workshop-1:${WORKSHOP_VALIDATOR_PROFILE}`;
export interface PackSummary { validator: string; files: number; expandedBytes: number; sheets?: number; mocVersions?: number[] }
const object = (value: unknown): Record<string, unknown> => record(value) ? value : {};
const list = (value: unknown): unknown[] => Array.isArray(value) ? value : [];
function rectangle(value: unknown): value is { x: number; y: number; w: number; h: number } {
  return record(value) && finite(value.x) && finite(value.y) && finite(value.w) && finite(value.h) && value.w > 0 && value.h > 0;
}
function depth(value: unknown): number {
  if (!value || typeof value !== 'object') return 0;
  let maximum = 0; for (const child of Object.values(value)) maximum = Math.max(maximum, depth(child));
  return maximum + 1;
}
export function validatePack(bytes: Uint8Array, meta: SubmissionMeta, maxMocVersion: number): PackSummary {
  if (meta.kind === 'pet') return validatePet(bytes, meta);
  if (meta.kind === 'theme') return validateTheme(bytes, meta);
  return validateCompanion(bytes, meta, maxMocVersion);
}

const THEME_JSON_CAP = 128 * 1024;
const THEME_FONT_CAP = 16 * 1024 * 1024;
const THEME_ASSET_TOTAL_CAP = 32 * 1024 * 1024;
const THEME_BUILT_IN_FONTS = new Set(['system', 'serif', 'mono', 'JetBrainsMono', 'monospace']);
const THEME_TOP_KEYS = new Set(['schema', 'id', 'name', 'title', 'description', 'tags', 'author', 'license', 'source', 'palette', 'surfaces', 'typography', 'shapes', 'components', 'emptyState']);
const THEME_COLOR_KEYS = new Set(['backdropTop', 'backdropBottom', 'glowPrimary', 'glowSecondary', 'surface', 'onSurface', 'onSurfaceVariant', 'outline', 'outlineVariant', 'primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer', 'userBubble', 'onUserBubble', 'assistantBubble', 'onAssistantBubble', 'codeWellBg', 'codeWellHeader', 'codeWellFg', 'codeWellBorder', 'link', 'heading', 'rule', 'userBubbleBorder', 'assistantBorder', 'composerFill', 'composerBorder', 'sendButton', 'onSendButton', 'inlineCodeBg', 'inlineCodeFg', 'patternInk', 'cardFill', 'chromeFill', 'sheetFill', 'hairline', 'textTertiary', 'success', 'warning', 'danger', 'info', 'syntaxKeyword', 'syntaxString', 'syntaxNumber', 'syntaxComment', 'syntaxFunction', 'syntaxType']);
const THEME_PALETTE_KEYS = new Set(['seed', 'seedDark', 'tintHue', 'tintChroma', 'glowOpacity', 'light', 'dark']);
const THEME_SURFACE_KEYS = new Set(['preset', 'chromeBlur', 'sheetBlur', 'cardOpacity', 'pillOpacity', 'hairlineWidth', 'rimOpacity', 'shadowOpacity', 'backdropImage', 'backdropOpacity', 'backdropRepeat', 'backdropAnimate', 'backdropBlur', 'backdropAlign', 'pattern', 'patternOpacity', 'patternScale', 'glowLayout']);
const THEME_TYPO_KEYS = new Set(['uiFont', 'readingFont', 'headingFont', 'codeFont', 'readingScale', 'readingLineHeight', 'headingScale', 'readingLetterSpacing', 'headingLetterSpacing', 'headingWeight', 'codeScale']);
const THEME_SHAPE_KEYS = new Set(['cornerScale', 'borderWidth', 'turnGap', 'inTurnGap', 'gutter', 'cornerStyle', 'bubbleCorners', 'bubbleRadius', 'cardRadius', 'codeRadius', 'composerRadius', 'bubblePadH', 'bubblePadV']);
const THEME_COMP_KEYS = new Set(['headerStyle', 'composerStyle', 'sendButtonStyle', 'userBubbleStyle', 'assistantStyle', 'useReadingFontForReply', 'suggestionCardStyle', 'codeBlockStyle', 'sendButtonShape', 'codeHeaderStyle', 'turnDivider', 'headingStyle', 'bulletStyle', 'headerTitleFont', 'userLabel', 'assistantLabel', 'assistantAvatar', 'userAvatar', 'composerHint']);
const THEME_EMPTY_KEYS = new Set(['layout', 'heroStyle', 'heroImage', 'useReadingFontForGreeting', 'showConnectedSubtitle', 'suggestionsDisplay', 'heroGlyph', 'heroScale', 'greeting', 'subtitle']);
const THEME_TEXT_KEYS = new Set(['zh', 'en']);
const THEME_IMAGE_EXTS = ['.png', '.webp', '.gif'];
const THEME_HEX = /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;
function safeThemeAsset(value: unknown, exts: string[]): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 80 &&
    /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(value) && !value.includes('..') &&
    exts.some(ext => value.toLowerCase().endsWith(ext));
}
function validFontMagic(bytes: Uint8Array): boolean {
  if (bytes.length < 12 || bytes.length > THEME_FONT_CAP) return false;
  if (bytes[0] === 0 && bytes[1] === 1 && bytes[2] === 0 && bytes[3] === 0) return true;
  const tag = String.fromCharCode(bytes[0]!, bytes[1]!, bytes[2]!, bytes[3]!);
  return tag === 'OTTO' || tag === 'true';
}
function checkThemeKeys(value: Record<string, unknown>, allowed: Set<string>): void {
  need(Object.keys(value).every(k => allowed.has(k)), 'theme_schema');
}
function checkThemeNum(value: unknown, min: number, max: number): void {
  if (value !== undefined) need(finite(value) && value >= min && value <= max, 'theme_schema');
}
function checkThemeColors(value: unknown): void {
  if (value === undefined) return;
  need(record(value), 'theme_schema');
  checkThemeKeys(value, THEME_COLOR_KEYS);
  for (const v of Object.values(value)) {
    if (v !== undefined && v !== null) need(typeof v === 'string' && THEME_HEX.test(v.trim()), 'theme_schema');
  }
}
function checkThemeEnum(value: unknown, allowed: readonly string[]): void {
  if (value !== undefined) need(typeof value === 'string' && allowed.includes(value), 'theme_schema');
}
function checkThemeBool(value: unknown): void {
  if (value !== undefined) need(typeof value === 'boolean', 'theme_schema');
}
function checkThemeText(value: unknown, maxRunes: number): void {
  if (value !== undefined) need(typeof value === 'string' && value.trim().length > 0 && [...value].length <= maxRunes && !/[\u0000-\u001f\ud800-\udfff]/u.test(value), 'theme_schema');
}
function checkThemeLocalized(value: unknown, maxRunes: number): void {
  if (value === undefined) return;
  need(record(value) && (value.zh !== undefined || value.en !== undefined), 'theme_schema');
  checkThemeKeys(value, THEME_TEXT_KEYS);
  checkThemeText(value.zh, maxRunes);
  checkThemeText(value.en, maxRunes);
}
const themeMagic = (bytes: Uint8Array, magic: string, offset = 0): boolean =>
  bytes.length >= offset + magic.length && [...magic].every((c, i) => bytes[offset + i] === c.charCodeAt(0));
// The canvas a WebP or GIF header declares; null when it is too short or not one of the three WebP layouts.
function themeImageCanvas(b: Uint8Array): [number, number] | null {
  const le16 = (at: number) => b[at]! | (b[at + 1]! << 8), le24 = (at: number) => le16(at) | (b[at + 2]! << 16);
  if (themeMagic(b, 'GIF8')) {
    // The decoder grows the logical screen to hold a first frame that reaches past it.
    if (b.length < 13) return null;
    let at = 13 + ((b[10]! & 0x80) === 0 ? 0 : 3 << ((b[10]! & 7) + 1));
    while (at + 9 < b.length) {
      if (b[at] === 0x2c) return [Math.max(le16(6), le16(at + 1) + le16(at + 5)), Math.max(le16(8), le16(at + 3) + le16(at + 7))];
      if (b[at] !== 0x21) return null;
      at += 2;
      while (at < b.length && b[at] !== 0) at += b[at]! + 1;
      at++;
    }
    return null;
  }
  if (b.length < 30) return null;
  if (themeMagic(b, 'VP8X', 12)) return [le24(24) + 1, le24(27) + 1];
  if (themeMagic(b, 'VP8 ', 12)) return [le16(26) & 0x3fff, le16(28) & 0x3fff];
  if (themeMagic(b, 'VP8L', 12)) { const bits = (le16(21) | (le16(23) << 16)) >>> 0; return [(bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1]; }
  return null;
}
// The header must match the extension. WebP and GIF are not decoded here; the
// App's engine does that, and a file it cannot decode just leaves the slot empty.
// Their declared canvas is held to the PNG limits, so a small file cannot ask
// the App for hundreds of MB.
function validateThemeImage(name: string, bytes: Uint8Array): void {
  const lower = name.toLowerCase();
  if (lower.endsWith('.png')) { validatePng(bytes); return; }
  need(lower.endsWith('.webp') ? themeMagic(bytes, 'RIFF') && themeMagic(bytes, 'WEBP', 8)
    : themeMagic(bytes, 'GIF87a') || themeMagic(bytes, 'GIF89a'), 'theme_image_header');
  const canvas = themeImageCanvas(bytes);
  need(canvas !== null && canvas[0] >= 1 && canvas[1] >= 1 && canvas[0] <= PET_LIMITS.sheetSide && canvas[1] <= PET_LIMITS.sheetSide &&
    canvas[0] * canvas[1] * 4 <= PET_LIMITS.sheetDecodedBytes, 'theme_image_size');
}
export function validateTheme(bytes: Uint8Array, meta: SubmissionMeta): PackSummary {
  const zip = new WorkshopArchive(bytes, 256);
  const candidates = [...zip.files.keys()].filter(name => /^(?:[^/]+\/)?theme\.json$/.test(name));
  need(candidates.length === 1, 'archive_pack_count');
  const manifestPath = candidates[0]!, prefix = manifestPath.slice(0, -'theme.json'.length);
  need([...zip.directories].every(name => prefix !== '' && name === prefix), 'theme_extra_file');
  const raw = zip.read(manifestPath, THEME_JSON_CAP), pack = strictJson(raw, THEME_JSON_CAP, 60);
  need(record(pack) && depth(pack) <= 60 && pack.schema === 1 && typeof pack.id === 'string' &&
    typeof pack.name === 'string' && pack.name.trim().length > 0 && [...pack.name].length <= 120, 'theme_schema');
  checkThemeKeys(pack, THEME_TOP_KEYS);
  need(pack.id === meta.id && pack.author === meta.author && pack.license === meta.license && pack.source === meta.source, 'theme_metadata_mismatch');

  if (pack.title !== undefined) {
    need(record(pack.title), 'theme_schema');
    checkThemeKeys(pack.title, new Set(['zh', 'en']));
    for (const v of Object.values(pack.title)) {
      if (v !== undefined) need(typeof v === 'string' && v.trim().length > 0 && [...v].length <= 120, 'theme_schema');
    }
  }
  if (pack.description !== undefined && pack.description !== '') {
    need(typeof pack.description === 'string' && pack.description.trim().length > 0 && [...pack.description].length <= 512, 'theme_schema');
  }
  if (pack.tags !== undefined) {
    need(Array.isArray(pack.tags) && pack.tags.length <= 8, 'theme_schema');
    const seenTags = new Set<string>();
    for (const tag of pack.tags) {
      need(typeof tag === 'string' && tag.trim().length > 0 && [...tag].length <= 32 && !seenTags.has(tag), 'theme_schema');
      seenTags.add(tag);
    }
  }

  const images = new Set<string>(), fonts = new Set<string>(), aliases = new Set<string>();
  const addAsset = (name: string, bucket: Set<string>) => {
    if (!bucket.has(name)) {
      const alias = nameAlias(name);
      need(!aliases.has(alias), 'theme_asset_alias');
      aliases.add(alias);
      bucket.add(name);
    }
  };

  if (pack.palette !== undefined) {
    need(record(pack.palette), 'theme_schema');
    checkThemeKeys(pack.palette, THEME_PALETTE_KEYS);
    if (pack.palette.seed !== undefined) need(typeof pack.palette.seed === 'string' && THEME_HEX.test(pack.palette.seed.trim()), 'theme_schema');
    if (pack.palette.seedDark !== undefined) need(typeof pack.palette.seedDark === 'string' && THEME_HEX.test(pack.palette.seedDark.trim()), 'theme_schema');
    checkThemeNum(pack.palette.tintHue, 0, 360);
    checkThemeNum(pack.palette.tintChroma, 0, 2);
    checkThemeNum(pack.palette.glowOpacity, 0, 1);
    checkThemeColors(pack.palette.light);
    checkThemeColors(pack.palette.dark);
  }

  const addImage = (value: unknown) => {
    if (value === undefined) return;
    need(safeThemeAsset(value, THEME_IMAGE_EXTS), 'theme_asset_name');
    addAsset(value, images);
  };

  if (pack.surfaces !== undefined) {
    need(record(pack.surfaces), 'theme_schema');
    checkThemeKeys(pack.surfaces, THEME_SURFACE_KEYS);
    checkThemeEnum(pack.surfaces.preset, ['glass', 'paper', 'flat', 'outlined']);
    checkThemeNum(pack.surfaces.chromeBlur, 0, 40);
    checkThemeNum(pack.surfaces.sheetBlur, 0, 40);
    checkThemeNum(pack.surfaces.cardOpacity, 0, 1);
    checkThemeNum(pack.surfaces.pillOpacity, 0, 1);
    checkThemeNum(pack.surfaces.hairlineWidth, 0, 3);
    checkThemeNum(pack.surfaces.rimOpacity, 0, 1);
    checkThemeNum(pack.surfaces.shadowOpacity, 0, 1);
    checkThemeNum(pack.surfaces.backdropOpacity, 0, 1);
    checkThemeBool(pack.surfaces.backdropRepeat);
    checkThemeBool(pack.surfaces.backdropAnimate);
    checkThemeNum(pack.surfaces.backdropBlur, 0, 40);
    checkThemeEnum(pack.surfaces.backdropAlign, ['center', 'top', 'bottom']);
    checkThemeEnum(pack.surfaces.pattern, ['none', 'dots', 'grid', 'lines', 'diagonal', 'grain']);
    checkThemeNum(pack.surfaces.patternOpacity, 0, 1);
    checkThemeNum(pack.surfaces.patternScale, 0.5, 3);
    checkThemeEnum(pack.surfaces.glowLayout, ['corners', 'top', 'bottom', 'center']);
    addImage(pack.surfaces.backdropImage);
  }

  if (pack.typography !== undefined) {
    need(record(pack.typography), 'theme_schema');
    checkThemeKeys(pack.typography, THEME_TYPO_KEYS);
    for (const role of ['uiFont', 'readingFont', 'headingFont', 'codeFont']) {
      const val = pack.typography[role];
      if (val !== undefined) {
        need(typeof val === 'string' && (THEME_BUILT_IN_FONTS.has(val) || safeThemeAsset(val, ['.ttf', '.otf'])), 'theme_font_role');
        if (!THEME_BUILT_IN_FONTS.has(val)) addAsset(val, fonts);
      }
    }
    checkThemeNum(pack.typography.readingScale, 0.85, 1.25);
    checkThemeNum(pack.typography.readingLineHeight, 1.2, 2.0);
    checkThemeNum(pack.typography.headingScale, 0.85, 1.35);
    checkThemeNum(pack.typography.readingLetterSpacing, -0.5, 2);
    checkThemeNum(pack.typography.headingLetterSpacing, -1, 4);
    const weight = pack.typography.headingWeight;
    if (weight !== undefined) need(whole(weight, 300, 900) && weight % 100 === 0, 'theme_schema');
    checkThemeNum(pack.typography.codeScale, 0.85, 1.2);
  }
  need(fonts.size <= 4, 'theme_font_count');

  if (pack.shapes !== undefined) {
    need(record(pack.shapes), 'theme_schema');
    checkThemeKeys(pack.shapes, THEME_SHAPE_KEYS);
    checkThemeNum(pack.shapes.cornerScale, 0, 1.6);
    checkThemeNum(pack.shapes.borderWidth, 0, 2.5);
    checkThemeNum(pack.shapes.turnGap, 12, 40);
    checkThemeNum(pack.shapes.inTurnGap, 4, 20);
    checkThemeNum(pack.shapes.gutter, 10, 28);
    checkThemeEnum(pack.shapes.cornerStyle, ['squircle', 'round', 'bevel']);
    checkThemeEnum(pack.shapes.bubbleCorners, ['uniform', 'tail', 'leaf']);
    for (const key of ['bubbleRadius', 'cardRadius', 'codeRadius', 'composerRadius']) checkThemeNum(pack.shapes[key], 0, 36);
    checkThemeNum(pack.shapes.bubblePadH, 10, 24);
    checkThemeNum(pack.shapes.bubblePadV, 6, 16);
  }

  if (pack.components !== undefined) {
    need(record(pack.components), 'theme_schema');
    checkThemeKeys(pack.components, THEME_COMP_KEYS);
    checkThemeEnum(pack.components.headerStyle, ['glass', 'ghost', 'outlined', 'minimal']);
    checkThemeEnum(pack.components.composerStyle, ['floatingGlass', 'solidPaper', 'outlined']);
    checkThemeEnum(pack.components.sendButtonStyle, ['primary', 'ink', 'tonal', 'outlined']);
    checkThemeEnum(pack.components.userBubbleStyle, ['soft', 'outlined', 'accent', 'minimal']);
    checkThemeEnum(pack.components.assistantStyle, ['plain', 'card', 'leftRule', 'quote']);
    checkThemeBool(pack.components.useReadingFontForReply);
    checkThemeEnum(pack.components.suggestionCardStyle, ['glass', 'paper', 'outlined', 'minimal']);
    checkThemeEnum(pack.components.codeBlockStyle, ['well', 'outlined', 'card']);
    checkThemeEnum(pack.components.sendButtonShape, ['circle', 'squircle', 'square']);
    checkThemeEnum(pack.components.codeHeaderStyle, ['bar', 'plain']);
    checkThemeEnum(pack.components.turnDivider, ['none', 'hairline', 'dashed', 'dots']);
    checkThemeEnum(pack.components.headingStyle, ['plain', 'accent', 'underline', 'marker']);
    checkThemeEnum(pack.components.bulletStyle, ['dot', 'dash', 'diamond', 'arrow', 'square']);
    checkThemeEnum(pack.components.headerTitleFont, ['ui', 'heading', 'code']);
    checkThemeLocalized(pack.components.userLabel, 16);
    checkThemeLocalized(pack.components.assistantLabel, 16);
    checkThemeLocalized(pack.components.composerHint, 30);
    addImage(pack.components.assistantAvatar);
    addImage(pack.components.userAvatar);
  }

  if (pack.emptyState !== undefined) {
    need(record(pack.emptyState), 'theme_schema');
    checkThemeKeys(pack.emptyState, THEME_EMPTY_KEYS);
    checkThemeEnum(pack.emptyState.layout, ['centered', 'editorial', 'compact']);
    const hero = pack.emptyState.heroStyle;
    checkThemeEnum(hero, ['whale', 'badge', 'customImage', 'hidden', 'glyph', 'seal']);
    checkThemeBool(pack.emptyState.useReadingFontForGreeting);
    checkThemeBool(pack.emptyState.showConnectedSubtitle);
    checkThemeEnum(pack.emptyState.suggestionsDisplay, ['expanded', 'collapsible', 'grid']);
    checkThemeText(pack.emptyState.heroGlyph, 4);
    checkThemeNum(pack.emptyState.heroScale, 0.6, 2);
    checkThemeLocalized(pack.emptyState.greeting, 40);
    checkThemeLocalized(pack.emptyState.subtitle, 60);
    addImage(pack.emptyState.heroImage);
    if (hero === 'customImage') need(pack.emptyState.heroImage !== undefined, 'theme_schema');
    if (hero === 'glyph' || hero === 'seal') need(pack.emptyState.heroGlyph !== undefined, 'theme_schema');
  }

  const kept = new Set([
    manifestPath,
    ...[...images].map(n => prefix + n),
    ...[...fonts].map(n => prefix + n),
    ...(meta.previewSource === 'theme-preview' ? ['preview.png'] : []),
  ]);
  need([...zip.files.keys()].every(name => kept.has(name)), 'theme_extra_file');
  let total = 0;
  for (const name of images) {
    const data = zip.read(prefix + name, Math.min(PET_LIMITS.sheetBytes, THEME_ASSET_TOTAL_CAP - total));
    total += data.length;
    validateThemeImage(name, data);
  }
  for (const name of fonts) {
    const data = zip.read(prefix + name, Math.min(THEME_FONT_CAP, THEME_ASSET_TOTAL_CAP - total));
    total += data.length;
    need(validFontMagic(data), 'theme_font_invalid');
  }
  if (meta.previewSource === 'theme-preview') need(zip.files.has('preview.png'), 'preview_missing');
  const previewBytes = meta.previewSource === 'theme-preview' ? zip.files.get('preview.png')!.size : 0;
  return { validator: VALIDATOR_VERSION, files: zip.files.size, expandedBytes: raw.length + total + previewBytes };
}
export function validatePet(bytes: Uint8Array, meta: SubmissionMeta): PackSummary {
  const zip = new WorkshopArchive(bytes, PET_LIMITS.archiveEntries);
  const candidates = [...zip.files.keys()].filter(name => /^(?:[^/]+\/)?pack\.json$/.test(name));
  need(candidates.length === 1, 'archive_pack_count');
  const manifestPath = candidates[0]!, prefix = manifestPath.slice(0, -'pack.json'.length);
  need([...zip.directories].every(name => prefix !== '' && name === prefix), 'pet_extra_file');
  const raw = zip.read(manifestPath, PET_LIMITS.packJsonBytes), pack = strictJson(raw, PET_LIMITS.packJsonBytes, 60);
  need(record(pack) && depth(pack) <= 60 && pack.schema === 1 && typeof pack.id === 'string' && pack.id.length > 0, 'pack_schema');
  need(pack.id === meta.id && pack.author === meta.author && pack.license === meta.license && pack.source === meta.source, 'pack_metadata_mismatch');
  const scale = pack.scale ?? 1, canvas = object(pack.canvas);
  need(whole(scale, 1, 4096) && whole(canvas.w, 1, 1 << 30) && whole(canvas.h, 1, 1 << 30) && rectangle(pack.contentBox), 'pack_overlay');
  const animations = object(pack.animations); need(Object.keys(animations).length > 0, 'pack_animations');
  const sheets = new Set<string>(), sheetAliases = new Set<string>();
  const frames: { sheet: string; cols: number; width: number; height: number; last: number }[] = [];
  for (const value of Object.values(animations)) {
    const a = object(value);
    need(typeof a.sheet === 'string' && a.sheet.length > 0 && a.sheet.length <= PET_LIMITS.sheetNameCharacters && encoder.encode(a.sheet).length <= 255 &&
      !a.sheet.startsWith('.') && !/[\/\\\0]/.test(a.sheet) && /\.png$/i.test(a.sheet), 'sheet_name');
    if (!sheets.has(a.sheet)) { const alias = nameAlias(a.sheet); need(!sheetAliases.has(alias), 'sheet_alias'); sheets.add(a.sheet); sheetAliases.add(alias); }
    need(whole(a.frameW, 1, 4096) && whole(a.frameH, 1, 4096) && whole(a.cols, 1, 4096) && rectangle(a.box), 'pack_overlay');
    need(a.frameW === Math.trunc(Math.fround(Math.fround(a.box.w) * scale)) && a.frameH === Math.trunc(Math.fround(Math.fround(a.box.h) * scale)), 'pack_geometry');
    need(Array.isArray(a.frames) && a.frames.length > 0, 'pack_frames'); let last = 0;
    for (const frame of a.frames) { need(record(frame) && whole(frame.i, 0, 1 << 30) && whole(frame.ms, 1, 1 << 30), 'pack_frames'); last = Math.max(last, frame.i); }
    frames.push({ sheet: a.sheet, cols: a.cols, width: a.frameW, height: a.frameH, last });
  }
  const known = (name: unknown) => need(typeof name === 'string' && Object.hasOwn(animations, name), 'pack_reference');
  const states = object(pack.states); need(list(states.idle).length > 0, 'pack_idle');
  for (const names of Object.values(states)) for (const name of list(names)) known(name);
  for (const tiers of Object.values(object(pack.tiers))) for (const tier of list(tiers)) known(object(tier).anim);
  for (const name of Object.values(object(pack.reactions))) known(name);
  const roam = object(pack.roam); if (roam.anim != null) known(roam.anim);
  for (const idle of Array.isArray(pack.idlePool) ? pack.idlePool : list(object(pack.idlePool).anims)) known(object(idle).anim);
  for (const bonus of Object.values(object(pack.bonus))) for (const name of list(object(bonus).anims)) known(name);
  need(sheets.size <= PET_LIMITS.sheetCount, 'sheet_count');
  const kept = new Set([manifestPath, ...[...sheets].map(name => prefix + name)]);
  need([...zip.files.keys()].every(name => kept.has(name)), 'pet_extra_file');
  let total = 0;
  for (const name of sheets) {
    const sheet = zip.read(prefix + name, Math.min(PET_LIMITS.sheetBytes, PET_LIMITS.totalSheetBytes - total)); total += sheet.length;
    const { width, height } = validatePng(sheet);
    for (const frame of frames.filter(frame => frame.sheet === name)) need(frame.cols <= Math.floor(width / frame.width) && Math.floor(frame.last / frame.cols) < Math.floor(height / frame.height), 'sheet_frame_bounds');
  }
  return { validator: VALIDATOR_VERSION, files: zip.files.size, expandedBytes: raw.length + total, sheets: sheets.size };
}

// Large motions run past 1 MiB; the app re-encodes every JSON it uploads.
export const COMPANION_JSON_CAP = 8 * 1024 * 1024;
const extensions = new Set(['json', 'moc3', 'png', 'jpg', 'jpeg', 'webp', 'wav', 'mp3', 'txt', 'md']);
const extension = (path: string) => path.slice(path.lastIndexOf('.') + 1).toLowerCase();
function companionReference(zip: WorkshopArchive, home: string, value: unknown, allowed: string[]): string {
  need(typeof value === 'string' && value.length > 0 && !/[\\\0:%?#]/.test(value) && !value.startsWith('/') && value.split('/').every(part => part && part !== '.' && part !== '..'), 'companion_reference');
  const path = home + value;
  need(zip.files.has(path) && allowed.includes(extension(path)), 'companion_reference'); return path;
}
function validateCompanionJson(data: Uint8Array, name: string, zip: WorkshopArchive, meta: SubmissionMeta): void {
  const value = strictJson(data, COMPANION_JSON_CAP, 60);
  // The local installer regenerates index.json; reject it on upload so
  // stale local indexes cannot be published as trusted model metadata.
  need(name !== 'character/index.json' && record(value), 'companion_json');
  if (name === 'character/character.json') {
    need(value.schema === 1 && typeof value.name === 'string' && value.name.trim().length > 0 &&
      value.author === meta.author && value.license === meta.license && value.source === meta.source, 'companion_metadata');
    const selected = companionReference(zip, 'character/', value.model, ['json']);
    need(/\.model3\.json$/i.test(selected), 'companion_model');
  }
  if (!/\.model3\.json$/i.test(name)) return;
  const home = name.slice(0, name.lastIndexOf('/') + 1), refs = object(value.FileReferences);
  need(value.Version === 3, 'companion_model');
  companionReference(zip, home, refs.Moc, ['moc3']);
  need(Array.isArray(refs.Textures) && refs.Textures.length > 0 && refs.Textures.length <= 64, 'companion_textures');
  for (const texture of refs.Textures) companionReference(zip, home, texture, ['png', 'jpg', 'jpeg', 'webp']);
  for (const field of ['Physics', 'Pose', 'UserData', 'DisplayInfo']) if (refs[field] != null) companionReference(zip, home, refs[field], ['json']);
  for (const expression of list(refs.Expressions)) { need(record(expression) && typeof expression.Name === 'string', 'companion_expression'); companionReference(zip, home, expression.File, ['json']); }
  for (const motions of Object.values(object(refs.Motions))) {
    need(Array.isArray(motions), 'companion_motion');
    for (const motion of motions) {
      need(record(motion), 'companion_motion'); companionReference(zip, home, motion.File, ['json']);
      if (motion.Sound != null && motion.Sound !== '') companionReference(zip, home, motion.Sound, ['wav', 'mp3']);
    }
  }
}
export function validateCompanion(bytes: Uint8Array, meta: SubmissionMeta, maxMocVersion: number): PackSummary {
  need(whole(maxMocVersion, 1, 255), 'moc_policy_unavailable', 503);
  const zip = new WorkshopArchive(bytes, 1000), mocVersions = new Set<number>();
  need([...zip.directories].every(name => name.startsWith('character/')), 'companion_forbidden_file');
  let expandedBytes = 0, models = 0, characterChecked = false;
  for (const name of zip.files.keys()) {
    need(name.startsWith('character/') && extensions.has(extension(name)), 'companion_forbidden_file');
    const data = zip.read(name, MEMBER_CAP); expandedBytes += data.length;
    if (extension(name) === 'json') {
      // The archive directory is complete before this loop. Resolve every
      // reference now, regardless of member order, and let this JSON's object
      // graph leave scope before reading another member or decoding a PNG.
      validateCompanionJson(data, name, zip, meta);
      if (name === 'character/character.json') characterChecked = true;
      if (/\.model3\.json$/i.test(name)) models++;
    } else if (extension(name) === 'png') validateTexture(data);
    else if (extension(name) === 'moc3') {
      need(data.length >= 5 && String.fromCharCode(...data.subarray(0, 4)) === 'MOC3', 'companion_moc');
      need(data[4]! >= 1 && data[4]! <= maxMocVersion, 'companion_moc_version'); mocVersions.add(data[4]!);
    } else need(data.length > 0, 'companion_empty_file');
  }
  need(characterChecked, 'companion_metadata');
  need(models > 0, 'companion_model');
  return { validator: VALIDATOR_VERSION, files: zip.files.size, expandedBytes, mocVersions: [...mocVersions].sort((a, b) => a - b) };
}
