import http from 'node:http';
import { once } from 'node:events';
import { setImmediate as nextTurn } from 'node:timers/promises';
import { join } from 'node:path';

// iOS smoke peer, derived from runtime/ohos/sim/fake-model.mjs.
// Script steps belong to the latest user turn, including a restored session.
export async function startGuestModel(workspace) {
  const calls = new Map();
  const scripts = {
    deny: "/bin/sh -c 'printf forbidden > /workspace/deny-marker'",
    osrelease: 'cat /etc/os-release',
    apkpath: 'command -v apk',
    pipeline: "cat /etc/os-release | grep '^ID='",
    full: 'apk --version',
    rootreadonly: "/bin/sh -c 'if printf forbidden > /etc/dsh-smoke-root; then exit 91; fi; test ! -e /etc/dsh-smoke-root && printf root-readonly'",
    rootdeny: "/bin/sh -c 'printf forbidden > /etc/dsh-smoke-root'",
    rootallow: "/bin/sh -c 'test ! -e /etc/dsh-smoke-root && printf approved > /etc/dsh-smoke-root && cat /etc/dsh-smoke-root'",
    rootafter: "/bin/sh -c 'test \"$(cat /etc/dsh-smoke-root)\" = approved || exit 92; if printf forbidden >> /etc/dsh-smoke-root; then exit 93; fi; test \"$(cat /etc/dsh-smoke-root)\" = approved && printf root-readonly-again'",
    identity: "/bin/sh -c 'uname -a; cat /etc/alpine-release; printf guest-ok > \"/workspace/中文 标记.txt\"; cat \"/workspace/中文 标记.txt\"; if command -v python3 >/dev/null; then printf python3=present:; python3 -c \"print(1+1)\"; else printf \"python3=absent\\n\"; fi'",
    exit: "/bin/sh -c 'printf exit > /workspace/exit-marker; exit 7'",
    cancel: "/bin/sh -c ': > /workspace/heartbeat; printf ready > /workspace/ready; while :; do printf x >> /workspace/heartbeat; sleep 0.1; done'",
    after: "/bin/sh -c 'printf after > /workspace/after-marker; printf guest-after-cancel'",
  };
  const requests = [];
  const server = http.createServer(async (req, res) => {
    try {
      if (req.method === 'GET' && req.url === '/v1/models') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ data: [{ id: 'ohos-script', object: 'model', owned_by: 'test' }] }));
        return;
      }
      if (req.method !== 'POST' || req.url !== '/v1/chat/completions') {
        res.writeHead(404); res.end(); return;
      }
      const chunks = []; let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 8 * 1024 * 1024) { res.writeHead(413); res.end(); return; }
        chunks.push(chunk);
      }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (body.stream !== true || !Array.isArray(body.messages)) {
        res.writeHead(400); res.end('streaming chat completion required'); return;
      }
      const tools = (body.tools ?? []).map((tool) => tool.function?.name);
      // DSH also emits clock/runtime context as user messages; find our authored turn marker.
      const lastUser = body.messages.findLastIndex((message) => message.role === 'user' &&
        JSON.stringify(message.content).includes('[DSH_IOS_SMOKE:'));
      if (tools.length && lastUser < 0) throw new Error('smoke turn marker missing');
      const results = body.messages.slice(lastUser + 1).filter((message) => message.role === 'tool');
      const scenario = JSON.stringify(body.messages[lastUser]?.content).match(/DSH_IOS_SMOKE:(deny|identity|osrelease|apkpath|pipeline|full|rootreadonly|rootdeny|rootallow|rootafter|exit|cancel|after)/)?.[1];
      if (tools.length && !scenario) throw new Error('unknown guest scenario');
      const step = tools.length && results.length === 0 ? ['bash', {
        description: 'Real guest CI approval fixture', command: scripts[scenario],
        sandbox_permissions: scenario === 'full' ? 'danger-full-access' : 'workspace-write', justification: 'Approve this one synthetic CI guest task in its isolated workspace.',
        ...(['rootdeny', 'rootallow'].includes(scenario) ? { linux_root_write: 'Test one-call writes to the isolated CI Linux installation.' } : {}),
      }] : undefined;
      if (step && !tools.includes(step[0])) {
        res.writeHead(422); res.end(JSON.stringify({ error: { message: `required test tool unavailable: ${step[0]}` } })); return;
      }
      requests.push({ toolResults: results.length, requestedTool: step?.[0] ?? null, offeredTools: tools, scenario });
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      const id = `chatcmpl-ohos-${requests.length}`;
      const send = (delta, finish_reason = null) => res.write(`data: ${JSON.stringify({
        id, object: 'chat.completion.chunk', created: 1, model: 'ohos-script',
        choices: [{ index: 0, delta, finish_reason }],
      })}\n\n`);
      send({ role: 'assistant', content: '' });
      await nextTurn();
      if (step) {
        const [name, args] = step;
        const callId = `call-ios-${requests.length}-${results.length}`;
        calls.set(scenario, callId);
        const chars = [...JSON.stringify(args)];
        const middle = Math.floor(chars.length / 2);
        send({ tool_calls: [{ index: 0, id: callId, type: 'function', function: { name, arguments: chars.slice(0, middle).join('') } }] });
        await nextTurn();
        send({ tool_calls: [{ index: 0, function: { arguments: chars.slice(middle).join('') } }] });
        send({}, 'tool_calls');
      } else {
        send({ content: tools.length ? 'O0 scripted round complete.' : '仿真测试' });
        send({}, 'stop');
      }
      res.end('data: [DONE]\n\n');
    } catch {
      if (!res.headersSent) res.writeHead(400);
      res.end();
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return {
    baseURL: `http://127.0.0.1:${server.address().port}/v1`, calls, requests,
    async close() {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}
