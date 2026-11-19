// Node's glibc getaddrinfo reads Android's host /etc, not the unpacked guest.
// Keep dns.lookup's public shape, but resolve through c-ares using the same
// resolv.conf GuestSetup updates for the proot tools. No host-NSS fallback.
import dns from 'node:dns';
import fs from 'node:fs';
import { dirname } from 'node:path';
import { isIP } from 'node:net';
import { networkInterfaces } from 'node:os';
import { promisify } from 'node:util';
import { domainToASCII } from 'node:url';
import { syncBuiltinESMExports } from 'node:module';

const nativeLookup = dns.lookup;
const nativePromiseLookup = dns.promises.lookup;
const NOT_FOUND = new Set(['ENODATA', 'ENOTFOUND']);
const normalizeHost = (name) => name.toLowerCase().replace(/\.$/, '');

export function readDnsConfig(resolvText, hostsText = '') {
  const servers = [];
  for (const line of resolvText.split(/\r?\n/u)) {
    const match = /^\s*nameserver\s+(\S+)/u.exec(line.replace(/[#;].*$/u, ''));
    if (match && !servers.includes(match[1])) servers.push(match[1]);
  }
  if (!servers.length) throw new Error('direct DNS: resolv.conf has no nameserver');
  const hosts = new Map();
  for (const line of hostsText.split(/\r?\n/u)) {
    const [address, ...names] = line.replace(/#.*/u, '').trim().split(/\s+/u);
    const family = isIP(address ?? '');
    if (!family) continue;
    for (const name of names) {
      const key = normalizeHost(name);
      const entries = hosts.get(key) ?? [];
      if (!entries.some((entry) => entry.address === address)) entries.push({ address, family });
      hosts.set(key, entries);
    }
  }
  return { servers, hosts };
}

function lookupError(hostname, causes) {
  const code = causes.some((error) => !NOT_FOUND.has(error?.code)) ? 'EAI_AGAIN' : 'ENOTFOUND';
  return Object.assign(new Error(`getaddrinfo ${code} ${hostname}`), {
    code, errno: code, syscall: 'getaddrinfo', hostname,
  });
}

/**
 * Independent resolvers per process/worker, one per address family. Both A and
 * AAAA are queried for family=0. `verbatim` preserves each RR response's order,
 * A then AAAA: c-ares cannot reproduce NSS's cross-family ordering. The app
 * default is ipv4first.
 * The returned refresh/close seams are also used by the local UDP tests.
 */
export function createLookup({ resolvConf, hostsFile, Resolver = dns.Resolver, watch = true } = {}) {
  let current;
  let configurationError;
  const refresh = () => {
    try {
      const config = readDnsConfig(fs.readFileSync(resolvConf, 'utf8'), fs.readFileSync(hostsFile, 'utf8'));
      const resolver = () => {
        const instance = new Resolver({ timeout: 2000, tries: 2 });
        instance.setServers(config.servers);
        return instance;
      };
      // One c-ares channel per family: a network that rejects every AAAA send
      // must not fail the A query sharing its channel (#55, #152).
      // In-flight requests retain their old resolvers. Never cancel another lookup.
      current = { ...config, resolvers: { 4: resolver(), 6: resolver() } };
      configurationError = undefined;
    } catch (error) {
      configurationError = error;
      if (!current) throw error;
    }
  };
  refresh();
  let watcher;
  if (watch) {
    watcher = fs.watch(dirname(resolvConf), { persistent: false }, (_event, filename) => {
      if (filename == null || ['resolv.conf', 'hosts'].includes(String(filename))) refresh();
    });
    watcher.on('error', (error) => { configurationError = error; });
  }

  async function resolve(hostname, options) {
    // A failed config read can recover without another event; a dead watcher cannot.
    if (configurationError && configurationError.syscall !== 'watch') refresh();
    if (configurationError) throw lookupError(hostname, [{ code: 'ESERVFAIL' }]);
    const snapshot = current;
    const family = options.family === 'IPv4' ? 4 : options.family === 'IPv6' ? 6 : (options.family ?? 0);
    const hints = options.hints ?? 0;
    let families = family ? [family] : [4, 6];
    const mapped = family === 6 && Boolean(hints & dns.V4MAPPED);
    if (mapped) families.push(4);
    if (hints & dns.ADDRCONFIG) {
      // Loopback alone does not establish Internet reachability. A platform that
      // denies getifaddrs cannot safely infer which family to suppress.
      try {
        const entries = Object.values(networkInterfaces()).flat();
        // An empty observation does not establish that either family is absent.
        // Nonempty observations retain the existing loopback/family filtering.
        if (entries.length) {
          const available = new Set(entries.filter((e) => e && !e.internal)
            .map((e) => e.family === 'IPv6' || e.family === 6 ? 6 : 4));
          families = families.filter((value) => available.has(value));
        }
      } catch { /* retain both families when Android denies interface enumeration */ }
    }
    const hostEntries = snapshot.hosts.get(normalizeHost(hostname));
    const failures = [];
    let answers;
    if (hostEntries) answers = hostEntries.filter((entry) => families.includes(entry.family))
      .map(({ address, family }) => ({ address, family }));
    else {
      const query = (value, resolver) => new Promise((done) => {
        resolver[value === 4 ? 'resolve4' : 'resolve6'](domainToASCII(hostname) || hostname, (error, addresses) => {
          done({ error, answers: error ? [] : addresses.map((address) => ({ address, family: value })) });
        });
      });
      const responses = await Promise.all(families.map((value) => query(value, snapshot.resolvers[value])));
      // Node passes REFUSED through instead of trying the other configured servers.
      // Keep partial-family success fast; only retry a lookup that has no address.
      if (snapshot.servers.length > 1 && !responses.some((response) => response.answers.length)) {
        await Promise.all(families.map(async (value, index) => {
          if (responses[index].error?.code !== 'EREFUSED') return;
          // c-ares can reorder its servers internally, and does not identify the
          // refusing server. Try this lookup's complete snapshot, without changing
          // or cancelling shared channels. A definitive negative answer ends it.
          for (const server of snapshot.servers) {
            const resolver = new Resolver({ timeout: 2000, tries: 2 });
            resolver.setServers([server]);
            const response = await query(value, resolver);
            responses[index] = response;
            if (!response.error || NOT_FOUND.has(response.error.code)) break;
          }
        }));
      }
      for (const response of responses) if (response.error) failures.push(response.error);
      answers = responses.flatMap((response) => response.answers);
    }
    if (mapped) {
      const ipv6 = answers.filter((entry) => entry.family === 6);
      const ipv4 = answers.filter((entry) => entry.family === 4);
      answers = [...ipv6, ...(!ipv6.length || (hints & dns.ALL) ? ipv4.map((entry) => ({
        address: `::ffff:${entry.address}`, family: 6,
      })) : [])];
    }
    const order = options.order ?? (options.verbatim === undefined ? dns.getDefaultResultOrder()
      : options.verbatim ? 'verbatim' : 'ipv4first');
    if (order !== 'verbatim') answers.sort((a, b) => order === 'ipv6first' ? b.family - a.family : a.family - b.family);
    if (!answers.length) throw lookupError(hostname, failures);
    return answers;
  }

  function lookup(hostname, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    // This IP-only call delegates option/callback validation to the exact Node
    // version in the runtime and performs no DNS/network access.
    nativeLookup('127.0.0.1', options, typeof callback === 'function' ? () => {} : callback);
    if (!hostname || typeof hostname !== 'string' || hostname.includes('\0') || isIP(hostname)) {
      return nativeLookup(hostname, options, callback);
    }
    const parsed = typeof options === 'number' ? { family: options } : (options ?? {});
    resolve(hostname, parsed).then(
      (answers) => parsed.all ? process.nextTick(callback, null, answers)
        : process.nextTick(callback, null, answers[0].address, answers[0].family),
      (error) => process.nextTick(callback, error),
    );
    return {};
  }
  function callbackPromise(hostname, options) {
    return new Promise((fulfill, reject) => lookup(hostname, options, (error, address, family) => {
      if (error) reject(error);
      else fulfill(Array.isArray(address) ? address : { address, family });
    }));
  }
  async function promiseLookup(hostname, options) {
    // Node 24's Promise API validates family more strictly than callback lookup.
    await nativePromiseLookup('127.0.0.1', options);
    return callbackPromise(hostname, options);
  }
  lookup[promisify.custom] = callbackPromise;
  return { lookup, promiseLookup, refresh, close: () => watcher?.close() };
}

export function installLookup(options) {
  const adapter = createLookup(options);
  dns.lookup = adapter.lookup;
  dns.promises.lookup = adapter.promiseLookup;
  syncBuiltinESMExports();
  return adapter;
}
