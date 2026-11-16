/**
 * dsh-restart-button — Host 半侧。
 *
 * 职责：
 * 1. 通过 `ctx.inject(['webServer'], ...)` 注册三个只读/动作路由，供浏览器半侧调用：
 *    GET  /api-restart-button/state   当前环境是否支持重启 + 上一次重启的回执
 *    POST /api-restart-button/restart 触发一次桌面端重启（确认由前端完成）
 *    GET  /api-restart-button/log     读取上一次重启的日志尾部（失败排查用）
 * 2. webServer 是可选服务：没有它（比如纯宿主组合）就只打一条 warn，插件本身照常激活，
 *    绝不能因为缺服务而让宿主 boot 失败。
 *
 * 安全栅栏与 dsh-checkup 一致：只接受无 Origin（同源导航）或
 * 回环地址 / dsh-app:// 的请求，跨源一律 403。
 */

import { requestRestart, readRestartLog, detectDesktopHost, describeTask } from './relaunch.js';

/** 上一次重启回执，保留给前端展示与日志读取。 */
let lastAttempt = null;

/** 可信任来源判定：无 Origin、回环、或桌面端自定义协议。 */
function isTrustedRequest(req) {
  const origin = req.headers && req.headers.origin;
  if (typeof origin !== 'string' || origin === '') return true;
  if (origin.startsWith('dsh-app://')) return true;
  return /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/i.test(origin);
}

function jsonRoute(path, handle) {
  return {
    kind: 'exact',
    path,
    handler: async (req, res) => {
      let status = 200;
      let payload;
      if (!isTrustedRequest(req)) {
        status = 403;
        payload = { ok: false, error: '拒绝跨源请求' };
      } else {
        try {
          [status, payload] = await handle(req);
        } catch (error) {
          status = 500;
          payload = { ok: false, error: error instanceof Error ? error.message : String(error) };
        }
      }
      res.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
      });
      res.end(JSON.stringify(payload));
    },
  };
}

/** 环境事实快照：前端据此决定按钮是否可用、文案说什么。 */
async function describeState() {
  const host = detectDesktopHost();
  const task = host.desktop ? await describeTask().catch(() => null) : null;
  return {
    desktop: host.desktop,
    electron: host.electron,
    profile: host.profile,
    platform: process.platform,
    task,
    lastAttempt,
    logPath: lastAttempt?.logPath ?? null,
  };
}

export function apply(ctx) {
  // 注册资源一律走 ctx.effect，插件卸载时自动清理路由。
  ctx.inject(['webServer'], (webCtx) => {
    const ws = webCtx.webServer;
    if (!ws || typeof ws.register !== 'function') {
      console.warn('[dsh-restart-button] webServer 不可用，浏览器半侧将拿不到重启接口');
      return;
    }

    webCtx.effect(
      () => ws.register(jsonRoute('/api-restart-button/state', async () => [200, await describeState()])),
      'dsh-restart-button: state route',
    );

    webCtx.effect(
      () => ws.register(jsonRoute('/api-restart-button/restart', async (req) => {
        // 必须 POST：GET 可能被预取/历史记录重放，误触发重启。
        if (req.method !== 'POST') return [405, { ok: false, error: '只接受 POST' }];
        try {
          const receipt = await requestRestart({ reason: 'manual' });
          lastAttempt = { ok: true, ...receipt };
          return [200, { ok: true, receipt: lastAttempt }];
        } catch (error) {
          const refused = error && error.name === 'RestartRefused';
          lastAttempt = {
            ok: false,
            at: new Date().toISOString(),
            reason: refused ? error.reason : (error instanceof Error ? error.message : String(error)),
            detail: refused ? error.detail : { message: String(error?.message ?? error) },
          };
          console.error('[dsh-restart-button] 重启被拒绝：', lastAttempt.reason, lastAttempt.detail);
          // 409：请求本身合法，但当前环境/前置条件不满足，前端据此显示可读错误。
          return [refused ? 409 : 500, { ok: false, error: lastAttempt.reason, detail: lastAttempt.detail }];
        }
      })),
      'dsh-restart-button: restart route',
    );

    webCtx.effect(
      () => ws.register(jsonRoute('/api-restart-button/log', async () => {
        if (lastAttempt?.logPath === undefined) {
          return [404, { ok: false, error: '还没有重启记录' }];
        }
        return [200, await readRestartLog(lastAttempt.logPath)];
      })),
      'dsh-restart-button: log route',
    );

    console.info('[dsh-restart-button] 已注册 /api-restart-button/{state,restart,log}');
  });
}
