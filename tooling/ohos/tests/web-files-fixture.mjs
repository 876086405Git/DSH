// Platform boundary fixture only: no actual picker, URI grant or Ark WebView.
// Product handlers and policy execute unchanged after import/type adaptation.
import assert from 'node:assert/strict';

export const state = {
  channels: [], calls: [], active: 0, throwConstructor: false, throwSelect: false,
  descriptors: new Map([['application/pdf', ['.pdf']], ['text/plain', ['.txt', '.text']]]),
  mimeCalls: [], throwMime: false,
  reset() {
    assert.equal(this.active, 0, 'test left a physical picker promise unsettled');
    this.channels = []; this.calls = []; this.throwConstructor = false; this.throwSelect = false;
    this.descriptors = new Map([['application/pdf', ['.pdf']], ['text/plain', ['.txt', '.text']]]);
    this.mimeCalls = []; this.throwMime = false;
  },
};

export class MethodChannel {
  constructor(messenger, name) { this.messenger = messenger; this.name = name; this.handler = null; state.channels.push(this); }
  setMethodCallHandler(handler) { this.handler = handler; }
}

export const uri = { URI: class {
  constructor(raw) {
    const value = new URL(raw);
    this.scheme = value.protocol.slice(0, -1);
    this.authority = (value.username || value.password ? value.username + ':' + value.password + '@' : '') + value.host;
    this.path = decodeURIComponent(value.pathname);
  }
} };

export const uniformTypeDescriptor = {
  getUniformDataTypeByMIMEType(mime) {
    state.mimeCalls.push(mime);
    if (state.throwMime) throw new Error('fixture MIME API unavailable');
    return mime;
  },
  getTypeDescriptor(type) {
    return state.descriptors.has(type) ? { filenameExtensions: state.descriptors.get(type) } : null;
  },
};

export const picker = {
  DocumentSelectOptions: class {},
  DocumentSelectMode: { FILE: 0 },
  DocumentViewPicker: class {
    constructor(context) {
      if (state.throwConstructor) throw new Error('fixture picker constructor failure');
      this.context = context;
    }
    select(options) {
      if (state.throwSelect) throw new Error('fixture synchronous select failure');
      const deferred = Promise.withResolvers();
      const call = { context: this.context, options, settled: false,
        resolve(value) { this.settled = true; deferred.resolve(value); },
        reject(error) { this.settled = true; deferred.reject(error); } };
      state.calls.push(call);
      state.active++;
      return deferred.promise.finally(() => state.active--);
    }
  },
};
