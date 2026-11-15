// Actual patched ToolRuntime/BatchSettlement; the lifecycle observer is synthetic.
// This checks result ordering, not filesystem durability or iPhone execution.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createSignalsFixture } from '../../../runtime/tests/fixtures/companion-signals-engine.mjs';

for (const enabled of [false, true]) {
  test(`companion result is sanitized once before lifecycle/session commit (lifecycle=${enabled})`, {
    skip: !process.env.IOS_GUEST_TEST_PREFIX,
  }, async () => {
    const previousPrefix = process.env.DSH_PREFIX;
    process.env.DSH_PREFIX = process.env.IOS_GUEST_TEST_PREFIX;
    const f = await createSignalsFixture();
    const marker = Symbol.for('dsh.go.ohos.sim');
    const owner = Symbol.for('dsh.go.ohos.lifecycle');
    const oldMarker = globalThis[marker], oldOwner = globalThis[owner];
    const producer = f.ctx.tools.dshGoCompanionResults;
    f.ctx.tools.register({
      name: 'synthetic_result', description: 'Return a fixed test value',
      parameters: { type: 'object', properties: {} },
      output: { schema: { type: 'string' }, render: (_args, text) => [{ type: 'text', text }] },
      execute: async () => 'synthetic value',
    });
    let checks = 0, journaled;
    f.ctx.tools.dshGoCompanionResults = {
      ...producer,
      beforeCommit(...args) {
        checks++;
        const result = producer.beforeCommit(...args);
        // A producer may sanitize metadata at this final boundary. The journal
        // and persisted event must receive that same value, not the earlier one.
        return { ...result, meta: { reviewed: 'synthetic-result' } };
      },
    };
    if (enabled) {
      globalThis[marker] = true;
      globalThis[owner] = {
        async gate() {}, async prepared() {}, failedGroup() {},
        withinCall: (_meta, body) => body(), run: (_meta, body) => body(),
        async outcome(meta, result) {
          journaled = {
            turn: meta.turn, step: meta.step,
            message: f.engine.llm.createToolResultMessage({ callId: meta.block.id,
              content: result.content, isError: result.isError }),
            ...(result.error?.info ? { error: result.error.info } : {}),
            ...(result.meta !== undefined ? { meta: result.meta } : {}),
          };
          assert.deepEqual(journaled.meta, { reviewed: 'synthetic-result' });
          return structuredClone(journaled);
        },
        async committed(meta) {
          const event = meta.session.snapshotEvents().find(event => event.type === 'tool/result'
            && event.sourceEventSeqs?.[0] === meta.callSeq);
          assert.deepEqual(event.data, journaled);
        },
      };
    }
    try {
      const { result, callId } = await f.execute('', { name: 'synthetic_result', args: {} });
      assert.equal(result.isError, false, JSON.stringify(result));
      assert.equal(checks, 1);
      const event = f.agent.session.snapshotEvents().find(event => event.type === 'tool/result'
        && event.data.message.toolCallId === callId);
      assert.deepEqual(event.data.meta, { reviewed: 'synthetic-result' });
      assert.deepEqual(result.meta, event.data.meta);
      assert.equal(journaled !== undefined, enabled);
    } finally {
      f.ctx.tools.dshGoCompanionResults = producer;
      if (oldMarker === undefined) delete globalThis[marker]; else globalThis[marker] = oldMarker;
      if (oldOwner === undefined) delete globalThis[owner]; else globalThis[owner] = oldOwner;
      await f.dispose();
      if (previousPrefix === undefined) delete process.env.DSH_PREFIX; else process.env.DSH_PREFIX = previousPrefix;
    }
  });
}
