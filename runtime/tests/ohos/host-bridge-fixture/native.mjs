// Private functional fixture for the real Host bridge. Never part of runtime payload.
import z from '__SCHEMA_MODULE__';
import { createHash } from 'node:crypto';
export const name = 'dsh-go-fixture-host-bridge';
export const Config = z.object({ label: z.string().default('initial-label') });
export function apply(ctx, config) {
  const state = { label: config.label, callbacks: 0, files: [], pendingCancelled: 0, bumps: 0 };
  const emitters = new Set();
  ctx.inject(['dshGo'], ctx => {
    ctx.dshGo.panel('proof', {
      view: { type: 'stack', children: [{ type: 'text', text: config.label }, { type: 'metric', label: 'Bumps', value: { $: 'data.bumps' } }] },
      data: (_scope, emit) => { emitters.add(emit); emit({ bumps: state.bumps, label: config.label }); return () => emitters.delete(emit); },
      actions: {
        bump: () => { state.bumps++; for (const emit of emitters) emit({ bumps: state.bumps, label: config.label }); return { toast: 'bumped' }; },
        hold: () => ({ pending: { label: 'private test', timeoutMs: 5000 }, result: signal => new Promise(resolve => signal.addEventListener('abort', () => { state.pendingCancelled++; resolve({ toast: 'cancelled' }); }, { once: true })) }),
        audio: () => ({ type: 'audio', op: 'play', instance: 'proof-audio', src: 'media:tone', key: 'proof-key' }),
        choose: () => ({ type: 'pickFile', action: 'selected', maxFiles: 1 }),
        selected: (_scope, event) => {
          state.callbacks++;
          state.files = event.value.files.map(file => {
            const bytes = ctx.dshGo.readPickedFile(file.handle);
            return { name: file.name, bytes: bytes.byteLength, sha256: createHash('sha256').update(bytes).digest('hex') };
          });
          return { patch: { callbacks: state.callbacks, files: state.files, status: event.value.status } };
        },
        state: () => ({ copy: JSON.stringify(state) }),
      },
    });
    ctx.dshGo.media('tone', () => {
      const bytes = Buffer.alloc(48);
      bytes.write('RIFF', 0); bytes.writeUInt32LE(40, 4); bytes.write('WAVEfmt ', 8);
      bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22);
      bytes.writeUInt32LE(16000, 24); bytes.writeUInt32LE(32000, 28); bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34);
      bytes.write('data', 36); bytes.writeUInt32LE(4, 40); bytes.writeInt16LE(100, 44); bytes.writeInt16LE(-100, 46);
      return { body: bytes, contentType: 'audio/wav' };
    });
  });
}
