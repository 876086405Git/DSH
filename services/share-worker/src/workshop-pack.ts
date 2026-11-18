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
  return meta.kind === 'pet' ? validatePet(bytes, meta) : validateCompanion(bytes, meta, maxMocVersion);
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
