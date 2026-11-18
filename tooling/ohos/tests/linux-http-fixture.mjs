// Explicit SDK boundary for the exact LinuxControl ETS body. Requests use real
// localhost TCP; this does not implement or certify the OH SDK's networking.
import { request as nodeRequest } from 'node:http';

export const calls = [];
export const http = {
  RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0 },
  InterceptorType: { REDIRECTION: 1 },
  HttpInterceptorChain: class {
    addChain(interceptors) { this.interceptors = interceptors; return true; }
    apply(handle) { handle.interceptors = this.interceptors; return true; }
  },
  createHttp() {
    const record = { destroyed: false }; calls.push(record);
    return {
      async request(url, options) {
        record.url = url; record.options = structuredClone(options);
        record.redirectAllowed = await this.interceptors[0].interceptorHandle({}, {});
        return new Promise((resolve, reject) => {
          const request = nodeRequest(url, { method: options.method, headers: options.header }, response => {
            const chunks = []; let count = 0;
            response.on('data', bytes => {
              count += bytes.length;
              if (count > options.maxLimit) request.destroy(Error('fixture response limit'));
              else chunks.push(Buffer.from(bytes));
            });
            response.on('error', reject);
            response.on('end', () => resolve({ responseCode: response.statusCode,
              header: response.headers, result: Buffer.concat(chunks).toString('utf8') }));
          });
          request.on('error', reject);
          request.setTimeout(options.readTimeout, () => request.destroy(Error('fixture timeout')));
          this.active = request;
          request.end(options.extraData);
        });
      },
      destroy() { record.destroyed = true; this.active?.destroy(); },
    };
  },
};
