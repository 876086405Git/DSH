// Host verification only: use the unchanged shared HTTP dispatcher under iOS-like
// platform/jitless/no-WebAssembly conditions. Product networking stays in dsh-preload.
Object.defineProperty(process, 'platform', { value: 'openharmony' });
delete globalThis.WebAssembly;
const { installFetch } = await import('../../../runtime/ohos/net/fetch.mjs');
installFetch();
