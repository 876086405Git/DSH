import http from 'node:http';
import { once } from 'node:events';
import { setImmediate as nextTurn } from 'node:timers/promises';
import { join } from 'node:path';

// A deterministic OpenAI Chat Completions peer. No model credentials or internet.
export async function startFakeModel(workspace, { bashCommand = "printf 'shell-ok\\n'" } = {}) {
  const file = join(workspace, '中文 测试.txt');
  const script = [
    ['write', { file_path: file, content: '初始内容\n', sandbox_permissions: 'danger-full-access', justification: 'O0 临时工作区审批验证' }],
    ['edit', { file_path: file, old_string: '初始内容', new_string: '修改后内容' }],
    ['read', { file_path: file }],
    ['grep', { pattern: '修改后内容', path: workspace }],
    ['bash', { description: 'Print a local simulation test marker', command: bashCommand, sandbox_permissions: 'danger-full-access', justification: 'O0 临时工作区命令审批验证' }],
  ];
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
      const results = body.messages.filter((message) => message.role === 'tool');
      const step = tools.length === 0 ? undefined : script[results.length];
      if (step && !tools.includes(step[0])) {
        res.writeHead(422); res.end(JSON.stringify({ error: { message: `required test tool unavailable: ${step[0]}` } })); return;
      }
      requests.push({ toolResults: results.length, requestedTool: step?.[0] ?? null, offeredTools: tools });
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
        const chars = [...JSON.stringify(args)];
        const middle = Math.floor(chars.length / 2);
        send({ tool_calls: [{ index: 0, id: `call-ohos-${results.length}`, type: 'function', function: { name, arguments: chars.slice(0, middle).join('') } }] });
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
    baseURL: `http://127.0.0.1:${server.address().port}/v1`, file, requests,
    async close() {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}
