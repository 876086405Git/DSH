// Independent iOS native-system tool contract. No native permission is granted here.
export const names = Object.freeze(['reminders_list', 'reminders_create', 'reminders_complete', 'contacts_search', 'contacts_create', 'photos_select', 'location_current', 'vision_ocr']);
export function invalid(message = 'Invalid system-tool value') { return Object.assign(new Error(message), { code: 'ERR_IOS_SYSTEM_INPUT' }); }
export function record(value, allowed, required = []) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw invalid();
  if (Object.keys(value).some(key => !allowed.includes(key)) || required.some(key => !Object.hasOwn(value, key))) throw invalid();
  return value;
}
export function text(value, max, empty = false) {
  if (typeof value !== 'string' || !value.isWellFormed() || value.includes('\0') || (!empty && !value.trim()) || Buffer.byteLength(value) > max) throw invalid();
  return value;
}
export function integer(value, min, max) { if (!Number.isSafeInteger(value) || value < min || value > max) throw invalid(); return value; }
export function boolean(value) { if (typeof value !== 'boolean') throw invalid(); return value; }
export function choice(value, values) { if (!values.includes(value)) throw invalid(); return value; }
export function opaque(value) { if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(value)) throw invalid(); return value; }
export function version(value) { if (typeof value !== 'string' || !/^[a-f0-9]{64}$/.test(value)) throw invalid(); return value; }
export function timestamp(value) {
  // Exact UTC instants only: no locale parsing, date-only or silent invalid-date normalization.
  if (typeof value !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(value) || !Number.isFinite(Date.parse(value)) || new Date(value).toISOString() !== value) throw invalid();
  return value;
}
const optional = (out, input, key, validate) => { if (Object.hasOwn(input, key)) out[key] = validate(input[key]); };
export function actionFor(name, input = {}) {
  if (!names.includes(name)) throw invalid('Unsupported iOS system tool');
  const args = {};
  switch (name) {
    case 'reminders_list':
      record(input, ['query', 'limit', 'include_completed']);
      optional(args, input, 'query', v => text(v, 128));
      args.limit = integer(input.limit === undefined ? 20 : input.limit, 1, 50);
      args.include_completed = boolean(input.include_completed === undefined ? false : input.include_completed); break;
    case 'reminders_create':
      record(input, ['title', 'notes', 'due', 'list_id'], ['title']); args.title = text(input.title, 256);
      optional(args, input, 'notes', v => text(v, 4096, true)); optional(args, input, 'due', timestamp); optional(args, input, 'list_id', opaque); break;
    case 'reminders_complete':
      record(input, ['id', 'version', 'completed'], ['id', 'version', 'completed']);
      args.id = opaque(input.id); args.version = version(input.version); args.completed = boolean(input.completed); break;
    case 'contacts_search':
      record(input, ['query', 'limit', 'fields'], ['query']); args.query = text(input.query, 128); args.limit = integer(input.limit === undefined ? 10 : input.limit, 1, 25);
      if (input.fields !== undefined) {
        if (!Array.isArray(input.fields) || input.fields.length > 2 || Object.keys(input.fields).length !== input.fields.length || new Set(input.fields).size !== input.fields.length) throw invalid();
        args.fields = input.fields.map(v => choice(v, ['phone', 'email'])).sort();
      } else args.fields = []; break;
    case 'contacts_create':
      record(input, ['given_name', 'family_name', 'phone', 'email'], ['given_name']); args.given_name = text(input.given_name, 128);
      optional(args, input, 'family_name', v => text(v, 128)); optional(args, input, 'phone', v => text(v, 64)); optional(args, input, 'email', v => text(v, 254)); break;
    case 'photos_select': record(input, ['limit']); args.limit = integer(input.limit === undefined ? 1 : input.limit, 1, 5); break;
    case 'location_current': record(input, []); break;
    case 'vision_ocr':
      record(input, ['image_handle', 'languages', 'max_bytes'], ['image_handle']); args.image_handle = opaque(input.image_handle);
      args.max_bytes = integer(input.max_bytes === undefined ? 8192 : input.max_bytes, 256, 16384);
      if (input.languages !== undefined) {
        if (!Array.isArray(input.languages) || !input.languages.length || input.languages.length > 3 || Object.keys(input.languages).length !== input.languages.length || new Set(input.languages).size !== input.languages.length) throw invalid();
        args.languages = input.languages.map(v => { if (typeof v !== 'string' || !/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(v)) throw invalid(); return v; });
      } else args.languages = []; break;
  }
  return Object.freeze({ kind: name, args: Object.freeze(args) });
}
