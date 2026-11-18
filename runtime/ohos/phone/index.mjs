import { PhoneQueue } from './queue.mjs';
import { createNativePhonePort } from './native-port.mjs';
import { registerPhoneRoutes } from './routes.mjs';
import { registerPhoneTools } from './tools.mjs';

export const name = 'dsh-go-ohos-phone';
export const inject = ['tools', 'ohosLifecycle', 'approval'];
const simulationSymbol = Symbol.for('dsh.go.ohos.sim');
const phoneSymbol = Symbol.for('dsh.go.ohos.phone');

export function apply(ctx) {
  if (process.platform !== 'openharmony' && globalThis[simulationSymbol] !== true) return;
  if (Object.hasOwn(globalThis, phoneSymbol)) throw new Error('One phone callback owner is allowed per engine');
  const queue = new PhoneQueue(createNativePhonePort(ctx.ohosLifecycle.bootId));
  let removeTools;
  try { removeTools = registerPhoneTools(ctx, queue); }
  catch (error) { queue.close(); throw error; }
  // A disposed bridge stays closed. Reloading a plugin must never replay an old call.
  Object.defineProperty(globalThis, phoneSymbol, { value: queue, configurable: false, writable: false });
  ctx.effect(() => () => { queue.close(); removeTools(); }, 'ohos phone shutdown');
  ctx.inject(['webServer'], webCtx => registerPhoneRoutes(webCtx, queue));
}
