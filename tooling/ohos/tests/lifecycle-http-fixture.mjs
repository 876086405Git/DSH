import nodeHttp from 'node:http';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

// A declared OH HTTP boundary adapter over real Linux sockets. It executes the
// production interceptor and request options, but cannot prove device behavior.
export const httpState = { created: 0, destroyed: 0, active: new Set(), requests: [],
  addAllowed: true, applyAllowed: true, beforeReply: null };
export const http = {
  RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0 },
  InterceptorType: { REDIRECTION: 'REDIRECTION' },
  HttpInterceptorChain: class {
    addChain(chain) { this.chain = chain; return httpState.addAllowed; }
    apply(client) { client.chain = this.chain; return httpState.applyAllowed; }
  },
  createHttp() {
    httpState.created++;
    const client = { closed: false, requestHandle: null, chain: null,
      destroy() {
        if (client.closed) throw new Error('HTTP client destroyed twice');
        client.closed = true; httpState.destroyed++; httpState.active.delete(client);
        client.requestHandle?.destroy();
      },
      request(url, options) {
        if (client.closed) throw new Error('request after destroy');
        httpState.requests.push({ url, options });
        return new Promise((resolve, reject) => {
          const request = nodeHttp.request(url, { method: options.method, headers: options.header }, response => {
            const chunks = []; let size = 0;
            response.on('data', chunk => {
              size += chunk.length;
              if (size > options.maxLimit) { request.destroy(new Error('response limit')); return; }
              chunks.push(chunk);
            });
            response.on('error', reject);
            response.on('end', async () => {
              try {
                const reply = { responseCode: response.statusCode, header: response.headers,
                  result: Buffer.concat(chunks).toString('utf8') };
                if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
                  const interceptor = client.chain?.find(item => item.interceptorType === 'REDIRECTION');
                  if (!interceptor || await interceptor.interceptorHandle({ url, options }, reply) !== false) {
                    throw new Error('fixture refuses to perform an unguarded redirect');
                  }
                }
                await httpState.beforeReply?.(reply, url);
                resolve(reply);
              } catch (error) { reject(error); }
            });
          });
          client.requestHandle = request; request.on('error', reject);
          request.setTimeout(options.readTimeout, () => request.destroy(new Error('read timeout')));
          request.end(options.extraData);
        });
      },
    };
    httpState.active.add(client); return client;
  },
};

export async function loadHttpTransport(source, directory) {
  let text = await fs.readFile(path.join(source, 'OhosLifecycleTransport.ets'), 'utf8');
  text = text.replace("import http from '@ohos.net.http';", `import { http } from '${import.meta.url}';`)
    .replace("import { LifecycleTransport, HostLifecycleObservation, LifecycleFailure } from './RuntimeLifecycle';",
      "import { type LifecycleTransport, type HostLifecycleObservation, LifecycleFailure } from './RuntimeLifecycle.mts';");
  const target = path.join(directory, 'OhosLifecycleTransport.mts'); await fs.writeFile(target, text);
  return await import(pathToFileURL(target));
}

export async function listen(t, handler) {
  const server = nodeHttp.createServer(handler); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}

export function request(url, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = nodeHttp.request(url, { method, headers }, res => {
      const chunks = []; res.on('data', c => chunks.push(c)); res.on('error', reject);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject); req.end(body);
  });
}
