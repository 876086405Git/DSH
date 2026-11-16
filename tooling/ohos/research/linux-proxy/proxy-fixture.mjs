import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { once } from 'node:events';
import { mkdir, readFile, writeFile, chmod } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';

const target = 'proxy-target.invalid';
const domestic = ['gitee.com', 'repo.gitee.com', 'huaweicloud.com', 'repo.huaweicloud.com'];
const hosts = new Set([target, ...domestic, '10.0.2.2']);
const roleOf = host => host === target ? 'target' : host === '10.0.2.2' ? 'host-alias' : domestic.includes(host) ? host : 'unexpected';
const clientOf = value => /^git\//i.test(value ?? '') ? 'git' : /^Go-http-client\//i.test(value ?? '') ? 'go' :
  /^Python-urllib\//i.test(value ?? '') ? 'python' : 'other';
const fixedError = name => Object.assign(new Error(name), { code: name });
export const NONCE = 'DSH_PROXY_RESEARCH_NONCE_V1\n';

/** Ephemeral loopback-only fixture. Returned settings contain secrets and must
 * remain in memory. events() returns a deliberately closed, non-secret schema. */
export async function createProxyFixtures({ directory, openssl = '/usr/bin/openssl' }) {
  await mkdir(directory, { recursive: false, mode: 0o700 });
  await chmod(directory, 0o700);
  const caKey = join(directory, 'ca.key'), ca = join(directory, 'ca.crt');
  const key = join(directory, 'server.key'), csr = join(directory, 'server.csr'), cert = join(directory, 'server.crt');
  const extensions = join(directory, 'extensions.conf');
  await writeFile(extensions, 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:10.0.2.2,IP:127.0.0.1,DNS:' + [target, ...domestic].join(',DNS:') + '\n', { mode: 0o600 });
  const execute = args => { try { execFileSync(openssl, args, { stdio: ['ignore', 'pipe', 'pipe'], timeout: 20000,
    env: { PATH: '/usr/bin:/bin', HOME: directory, TMPDIR: directory, LANG: 'C' } }); }
    catch { throw fixedError('ERR_PROXY_FIXTURE_CERTIFICATE'); } };
  execute(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', caKey, '-out', ca,
    '-days', '1', '-subj', '/CN=DSH-Proxy-Research-CA']);
  execute(['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', csr, '-subj', '/CN=' + target]);
  execute(['x509', '-req', '-in', csr, '-CA', ca, '-CAkey', caKey, '-CAcreateserial', '-out', cert,
    '-days', '1', '-extfile', extensions]);
  await chmod(caKey, 0o600); await chmod(key, 0o600);
  const tls = { key: await readFile(key), cert: await readFile(cert) };
  const caPem = await readFile(ca, 'utf8');
  const username = 'proxy-research', password = randomBytes(24).toString('hex');
  const expected = 'Basic ' + Buffer.from(username + ':' + password).toString('base64');
  const events = [], sockets = new Set(), servers = [];
  const record = fields => {
    if (events.length >= 256) throw fixedError('ERR_PROXY_FIXTURE_EVENT_LIMIT');
    events.push({ atNs: process.hrtime.bigint().toString(), ...fields });
  };
  const track = socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {}); };
  function origin(kind, request, response) {
    const reply = (status, type, body) => {
      response.writeHead(status, { 'content-type': type, 'content-length': Buffer.byteLength(body), connection: 'close' });
      response.end(body);
    };
    let host = '', path = '';
    try { const url = new URL(request.url, 'https://' + request.headers.host); host = url.hostname; path = url.pathname; }
    catch { response.writeHead(400); response.end(); return; }
    const route = path === '/nonce' ? 'nonce' : path === '/repo/info/refs' ? 'git-info' :
      path === '/repo/HEAD' ? 'git-head' : path === '/api/v3/meta' || path === '/meta' ? 'api-meta' : 'unexpected';
    record({ boundary: 'origin', transport: kind, hostRole: roleOf(host), route, client: clientOf(request.headers['user-agent']) });
    if (!hosts.has(host)) { response.writeHead(400); response.end(); return; }
    if (route === 'nonce') reply(200, 'text/plain', NONCE);
    else if (route === 'git-info') reply(200, 'text/plain', '');
    else if (route === 'git-head') reply(200, 'text/plain', 'ref: refs/heads/main\n');
    else if (route === 'api-meta') reply(200, 'application/json', '{"proxyResearch":"ok"}\n');
    else { response.writeHead(404); response.end(); }
  }
  async function listen(server) {
    server.on('connection', track); server.on('clientError', (_error, socket) => socket.destroy());
    server.listen(0, '127.0.0.1'); await once(server, 'listening'); servers.push(server); return server.address().port;
  }
  const httpOriginPort = await listen(http.createServer((a, b) => origin('http', a, b)));
  const httpsOriginPort = await listen(https.createServer(tls, (a, b) => origin('https', a, b)));
  function authorize(kind, operation, request, reject) {
    const authorized = request.headers['proxy-authorization'] === expected;
    record({ boundary: 'proxy', transport: kind, operation, authorized,
      authorizationPresent: typeof request.headers['proxy-authorization'] === 'string', client: clientOf(request.headers['user-agent']) });
    if (!authorized) reject();
    return authorized;
  }
  function proxy(kind, request, response) {
    if (!authorize(kind, 'request', request, () => {
      response.writeHead(407, { 'proxy-authenticate': 'Basic realm="fixture"' }); response.end();
    })) return;
    let url;
    try { url = new URL(request.url); } catch { response.writeHead(400); response.end(); return; }
    if (url.protocol !== 'http:' || !hosts.has(url.hostname) || Number(url.port) !== httpOriginPort || request.method !== 'GET') {
      response.writeHead(403); response.end(); return;
    }
    const forward = http.request({ host: '127.0.0.1', port: httpOriginPort, method: 'GET', path: url.pathname + url.search,
      headers: { host: url.host, 'user-agent': request.headers['user-agent'] ?? 'fixture' } }, upstream => {
      response.writeHead(upstream.statusCode, upstream.headers); upstream.pipe(response);
    });
    forward.on('error', () => { response.writeHead(502); response.end(); }); forward.end();
  }
  function connect(kind, request, socket, head) {
    if (!authorize(kind, 'connect', request, () => socket.end('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="fixture"\r\nConnection: close\r\nProxy-Connection: close\r\nContent-Length: 0\r\n\r\n'))) return;
    let url;
    try { url = new URL('https://' + request.url); } catch { socket.destroy(); return; }
    const requestedPort = Number(url.port || 443);
    if (!hosts.has(url.hostname) || !(requestedPort === httpsOriginPort || url.hostname === target && requestedPort === 443)) {
      socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); return;
    }
    const upstream = net.connect({ host: '127.0.0.1', port: httpsOriginPort }); track(upstream);
    upstream.once('connect', () => {
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      socket.pipe(upstream); upstream.pipe(socket);
    });
    upstream.on('error', () => socket.destroy()); socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy()); upstream.on('close', () => socket.destroy());
  }
  const plain = http.createServer((a, b) => proxy('http', a, b)); plain.on('connect', (a, b, c) => connect('http', a, b, c));
  const secure = https.createServer(tls, (a, b) => proxy('https', a, b)); secure.on('connect', (a, b, c) => connect('https', a, b, c));
  const httpProxyPort = await listen(plain), httpsProxyPort = await listen(secure);
  return {
    // The child receives this object by an anonymous pipe. Never serialize it
    // to a file, argv, stdout, stderr, record, assertion detail or status.
    settings: { httpOriginPort, httpsOriginPort, httpProxyPort, httpsProxyPort, username, password, caPem },
    events: () => events.map(value => ({ ...value })),
    async close() { for (const socket of sockets) socket.destroy(); await Promise.all(servers.map(server => new Promise(resolve => server.close(resolve)))); },
  };
}
