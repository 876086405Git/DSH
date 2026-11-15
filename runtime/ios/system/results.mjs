import { record, text, integer, boolean, choice, opaque, version, timestamp, invalid } from './actions.mjs';
const list = (v, max, validate) => {
  if (!Array.isArray(v) || v.length > max || Object.keys(v).length !== v.length) throw invalid();
  return v.map(validate);
};
const number = (v, lo, hi) => { if (typeof v !== 'number' || !Number.isFinite(v) || v < lo || v > hi) throw invalid(); return v; };
const reminder = v => {
  record(v, ['id', 'version', 'title', 'completed', 'due'], ['id', 'version', 'title', 'completed']);
  const out = { id: opaque(v.id), version: version(v.version), title: text(v.title, 256), completed: boolean(v.completed) };
  if (v.due !== undefined) out.due = timestamp(v.due);
  return out;
};
export function resultFor(action, value) {
  // The transport must enforce the byte cap BEFORE JSON parsing as well.
  if (Buffer.byteLength(JSON.stringify(value)) > 32768) throw invalid('Native result too large');
  switch (action.kind) {
    case 'reminders_list':
      record(value, ['scope', 'items', 'truncated'], ['scope', 'items', 'truncated']);
      return { scope: choice(value.scope, ['full']), items: list(value.items, action.args.limit, reminder), truncated: boolean(value.truncated) };
    case 'reminders_create': case 'reminders_complete':
      record(value, ['committed', 'item'], ['committed', 'item']);
      if (value.committed !== true) throw invalid('Write not committed');
      {
        const item = reminder(value.item);
        if (action.kind === 'reminders_complete' && (item.id !== action.args.id || item.completed !== action.args.completed)) throw invalid('Write result does not match requested reminder');
        return { committed: true, item };
      }
    case 'contacts_search':
      record(value, ['scope', 'items', 'truncated'], ['scope', 'items', 'truncated']);
      return { scope: choice(value.scope, ['limited', 'full']), truncated: boolean(value.truncated), items: list(value.items, action.args.limit, v => {
        record(v, ['id', 'display_name', ...action.args.fields], ['id', 'display_name']);
        const out = { id: opaque(v.id), display_name: text(v.display_name, 256) };
        for (const field of action.args.fields) if (v[field] !== undefined) out[field] = list(v[field], 3, x => text(x, field === 'phone' ? 64 : 254));
        return out;
      }) };
    case 'contacts_create':
      record(value, ['committed', 'id'], ['committed', 'id']);
      if (value.committed !== true) throw invalid('Write not committed');
      return { committed: true, id: opaque(value.id) };
    case 'photos_select':
      record(value, ['items'], ['items']);
      return { items: list(value.items, action.args.limit, v => {
        record(v, ['handle', 'width', 'height', 'bytes', 'expires_at'], ['handle', 'width', 'height', 'bytes', 'expires_at']);
        const width = integer(v.width, 1, 8192), height = integer(v.height, 1, 8192);
        if (width * height > 24000000) throw invalid('Image pixel budget exceeded');
        return { handle: opaque(v.handle), width, height, bytes: integer(v.bytes, 1, 10485760), expires_at: timestamp(v.expires_at) };
      }) };
    case 'location_current':
      record(value, ['latitude', 'longitude', 'horizontal_accuracy_m', 'accuracy_authorization', 'timestamp'], ['latitude', 'longitude', 'horizontal_accuracy_m', 'accuracy_authorization', 'timestamp']);
      return { latitude: number(value.latitude, -90, 90), longitude: number(value.longitude, -180, 180), horizontal_accuracy_m: number(value.horizontal_accuracy_m, 0, 40075017), accuracy_authorization: choice(value.accuracy_authorization, ['full', 'reduced']), timestamp: timestamp(value.timestamp) };
    case 'vision_ocr':
      record(value, ['text', 'truncated'], ['text', 'truncated']);
      return { text: text(value.text, action.args.max_bytes, true), truncated: boolean(value.truncated) };
    default: throw invalid();
  }
}
