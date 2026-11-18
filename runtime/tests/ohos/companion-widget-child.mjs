// Independent OS process, loading the same product ETS, for disk/lock evidence.
import { widgetFixture, until } from './companion-widget-fixture.mjs';
const [mode, root, time] = process.argv.slice(2);
const f = await widgetFixture(null, { root, now: Number(time), forms: [] });
if (mode === 'hold') {
  const keep = setInterval(() => {}, 1000); // Test process lifetime, never product.
  f.change({ forms: [{ formId: 'held', bundleName: 'ccchimneyyy.dsh.go', moduleName: 'entry',
    abilityName: 'CompanionFormAbility', formName: 'companion_room' }],
    update: async () => { process.stdout.write('LOCKED\n'); await new Promise(() => {}); } });
  f.call(new Map([['name', 'written-by-child'], ['line', 'durable'], ['saidAt', Number(time)]]));
  process.on('SIGTERM', () => { clearInterval(keep); process.exit(143); });
} else {
  const form = f.form();
  const initial = form.onAddForm({ parameters: { 'ohos.extra.param.key.form_identity': 'child-form' } });
  await until(() => (f.updates.length > 0 || f.errors.length > 0) && f.fds.size === 0);
  process.stdout.write(JSON.stringify({ initial, updates: f.updates, errors: f.errors,
    snapshotReads: f.calls.filter(c => c[0] === 'open' && c[1].endsWith('/snapshot.json')).length }) + '\n');
  form.onStop();
}
