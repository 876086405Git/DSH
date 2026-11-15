// 未经目标 SDK / 真机核实；页面与资源接线见 companion-widget.md。
export type WidgetValue = string | number | null;

export class WidgetValues {
  name?: string;
  status?: string;
  activity?: string;
  untilMs?: number;
  statusAsleep?: string;
  statusWaiting?: string;
  bond?: number;
  line?: string;
  saidAt?: number;
}

export interface WidgetView {
  ready: boolean;
  name: string;
  nameDefault: boolean;
  status: string;
  statusDefault: string;
  line: string;
  pearls: string;
  pose: string;
  openUri: string;
}

const TEXT_KEYS: string[] = ['name', 'status', 'activity', 'statusAsleep', 'statusWaiting', 'line'];
const NUMBER_KEYS: string[] = ['untilMs', 'bond', 'saidAt'];

export function widgetPatch(raw: Object | null | undefined): Map<string, WidgetValue> | undefined {
  if (!(raw instanceof Map)) return undefined;
  const result: Map<string, WidgetValue> = new Map<string, WidgetValue>();
  const values: Map<Object, Object | null> = raw as Map<Object, Object | null>;
  values.forEach((value: Object | null, key: Object): void => {
    if (typeof key !== 'string') return;
    const text: boolean = TEXT_KEYS.includes(key);
    if (!text && !NUMBER_KEYS.includes(key)) return;
    if (value === null) { result.set(key, null); return; }
    // Android ignores booleans/objects. The nine production keys have fixed types.
    if (typeof value !== 'string' && typeof value !== 'number') return;
    if (text && typeof value === 'string' && value.length <= 4096) result.set(key, value);
    else if (!text && typeof value === 'number' && Number.isSafeInteger(Math.trunc(value))) {
      result.set(key, Math.trunc(value));
    } else throw new Error('Invalid companion widget field: ' + key);
  });
  return result;
}

export function widgetMerge(values: WidgetValues, patch: Map<string, WidgetValue>): WidgetValues {
  patch.forEach((value: WidgetValue, key: string): void => {
    switch (key) {
      case 'name': values.name = value === null ? undefined : value as string; break;
      case 'status': values.status = value === null ? undefined : value as string; break;
      case 'activity': values.activity = value === null ? undefined : value as string; break;
      case 'untilMs': values.untilMs = value === null ? undefined : value as number; break;
      case 'statusAsleep': values.statusAsleep = value === null ? undefined : value as string; break;
      case 'statusWaiting': values.statusWaiting = value === null ? undefined : value as string; break;
      case 'bond': values.bond = value === null ? undefined : value as number; break;
      case 'line': values.line = value === null ? undefined : value as string; break;
      case 'saidAt': values.saidAt = value === null ? undefined : value as number; break;
    }
  });
  return values;
}

export function widgetDecode(text: string): WidgetValues {
  const raw: WidgetValues = JSON.parse(text) as WidgetValues;
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('Invalid widget snapshot');
  const fields: Map<string, Object | null> = new Map<string, Object | null>();
  const strings: (string | undefined)[] = [raw.name, raw.status, raw.activity, raw.statusAsleep, raw.statusWaiting, raw.line];
  const numbers: (number | undefined)[] = [raw.untilMs, raw.bond, raw.saidAt];
  for (let index: number = 0; index < strings.length; index++) {
    const value: string | undefined = strings[index];
    if (value === undefined) continue;
    if (typeof value !== 'string') throw new Error('Invalid widget snapshot text');
    fields.set(TEXT_KEYS[index], value);
  }
  for (let index: number = 0; index < numbers.length; index++) {
    const value: number | undefined = numbers[index];
    if (value === undefined) continue;
    if (typeof value !== 'number' || !Number.isSafeInteger(value)) throw new Error('Invalid widget snapshot number');
    fields.set(NUMBER_KEYS[index], value);
  }
  return widgetMerge(new WidgetValues(), widgetPatch(fields)!);
}

export function widgetView(values: WidgetValues, now: Date, ready: boolean = true): WidgetView {
  const time: number = now.getTime();
  const hour: number = now.getHours();
  const night: boolean = hour >= 23 || hour < 6;
  const busy: boolean = (values.activity ?? 'idle') !== 'idle' && (values.untilMs ?? 0) > time;
  const bond: number = Math.max(-1, Math.min(3, values.bond ?? -1));
  let status: string | undefined;
  let fallback: string = '';
  if (busy) status = values.status;
  else if (night) { status = values.statusAsleep; if (status === undefined) fallback = 'asleep'; }
  else { status = values.statusWaiting; if (status === undefined) fallback = 'waiting'; }
  const view: WidgetView = {
    ready: ready, name: values.name ?? '', nameDefault: values.name === undefined,
    status: status ?? '', statusDefault: fallback,
    line: time - (values.saidAt ?? 0) < 12 * 3600000 ? values.line ?? '' : '',
    pearls: bond >= 0 ? '●'.repeat(bond + 1) + '○'.repeat(3 - bond) : '',
    pose: night && !busy ? 'sleeping' : bond >= 2 ? 'happy' : 'idle',
    openUri: 'dshgo://open/companion'
  };
  return view;
}
