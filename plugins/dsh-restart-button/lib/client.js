/**
 * dsh-restart-button — 浏览器半侧。
 *
 * 形态：侧边栏底部一排（`sidebar.footer.action`），与设置齿轮同一排。
 * 交互：点按钮 → 确认弹窗 → 调 Host 重启接口 → 成功则显示「正在重启」遮罩并断开；
 *       失败则弹错误框，列出具体原因与重试按钮。
 *
 * 不变量：
 * - 工厂函数零副作用，所有监听/定时器都在 apply 内用 ctx.effect 注册并返回清理。
 * - 不读写别的插件 DOM，只用主题令牌 --dsw-alias-*。
 * - 固定定位的遮罩一律 portal 到 document.body（composer/footer 有 transform 会困住 fixed）。
 */

window.__ModuleLoader__.load({
  id: 'dsh-restart-button',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    const { useState, useEffect, useRef, useCallback } = React;

    const NS = 'dsh-restart-button';
    const ENDPOINT = {
      state: '/api-restart-button/state',
      restart: '/api-restart-button/restart',
      log: '/api-restart-button/log',
    };

    /** 中文文案（兜底字典 + 注册字典共用一份，避免两处漂移）。 */
    const ZH = {
      'button.label': '重启',
      'button.aria': '重启 DeepSeek Harness',
      'button.title': '重启 DeepSeek Harness',
      'confirm.title': '要重启 DeepSeek Harness 吗？',
      'confirm.body': '应用会先关闭再自动打开。这个窗口里还在跑的任务会被中断。',
      'confirm.cancel': '取消',
      'confirm.ok': '立即重启',
      'progress.title': '正在重启…',
      'progress.body': '应用正在关闭，稍后会自动打开；如果没起来，从开始菜单再点一次即可。',
      'error.title': '重启失败',
      'error.retry': '重试一次',
      'error.close': '关闭',
      'error.unsupported': '当前不是桌面端窗口，没有可重启的应用。',
      'log.title': '发生了什么',
      'log.copy': '复制',
      'log.copied': '已复制',
      'log.empty': '还没有重启记录。',
    };

    const EN = {
      'button.label': 'Restart',
      'button.aria': 'Restart DeepSeek Harness',
      'button.title': 'Restart DeepSeek Harness',
      'confirm.title': 'Restart DeepSeek Harness?',
      'confirm.body': 'The app will close and reopen. Anything still running in this window will be interrupted.',
      'confirm.cancel': 'Cancel',
      'confirm.ok': 'Restart',
      'progress.title': 'Restarting…',
      'progress.body': 'The app is closing. It reopens on its own; if it does not, open it again from the Start menu.',
      'error.title': 'Restart failed',
      'error.retry': 'Try again',
      'error.close': 'Close',
      'error.unsupported': 'This is not a desktop window, so there is nothing to restart.',
      'log.title': 'What happened',
      'log.copy': 'Copy',
      'log.copied': 'Copied',
      'log.empty': 'No restart record yet.',
    };

    /** 语言服务缺失/未命中时的兜底。 */
    const FALLBACK = ZH;

    // ── 样式：只用主题令牌，dark/light 自动跟随 ──
    const CSS = `
.dsrb-foot {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  /* 整行宽度由宿主 .footerActions 决定；这里靠右对齐贴近侧栏右下角 */
  margin-left: auto;
  height: 32px;
  padding: 0 10px;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  color: var(--dsw-alias-label-secondary);
  font: inherit;
  font-size: 13px;
  line-height: 1;
  cursor: pointer;
  box-sizing: border-box;
  max-width: 100%;
  transition: background-color .12s ease, color .12s ease, border-color .12s ease;
}
.dsrb-foot:hover {
  background: var(--dsw-alias-bg-layer-2);
  color: var(--dsw-alias-label-primary);
}
.dsrb-foot:focus-visible {
  outline: 2px solid var(--dsw-alias-brand-primary);
  outline-offset: 1px;
}
/* 贴到侧栏右下角时的形态：完全透明背景，与侧栏其它图标按钮观感一致。
   只在 hover / 按下时给出轻微底色，让用户能确认这里是可点的。 */
.dsrb-foot-pinned {
  margin-left: 0;
  padding: 0 12px 0 10px;
  border-color: transparent;
  background: transparent;
  box-shadow: none;
}
.dsrb-foot-pinned:hover {
  background: var(--dsw-alias-bg-layer-2);
  border-color: transparent;
}
.dsrb-foot[disabled] {
  cursor: progress;
  opacity: .6;
}
.dsrb-foot-icon {
  display: block;
  width: 16px;
  height: 16px;
  flex: none;
}
.dsrb-foot-spin { animation: dsrb-spin 1s linear infinite; }
@keyframes dsrb-spin { to { transform: rotate(360deg); } }
.dsrb-foot-label {
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.dsrb-scrim {
  position: fixed;
  inset: 0;
  z-index: 2147482000;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px;
  background: rgba(0, 0, 0, .42);
}
.dsrb-dialog {
  width: min(480px, calc(100vw - 48px));
  max-height: calc(100vh - 72px);
  overflow: auto;
  padding: 20px 20px 16px;
  border: 1px solid var(--dsw-alias-border-l1);
  border-radius: 14px;
  background: var(--dsw-alias-bg-overlay);
  color: var(--dsw-alias-label-primary);
  box-shadow: 0 18px 48px rgba(0, 0, 0, .34);
}
.dsrb-title {
  margin: 0 0 8px;
  font-size: 15px;
  font-weight: 600;
  line-height: 1.4;
  color: var(--dsw-alias-label-primary);
}
.dsrb-body {
  margin: 0 0 14px;
  font-size: 13px;
  line-height: 1.65;
  color: var(--dsw-alias-label-secondary);
  white-space: pre-wrap;
  word-break: break-word;
}
.dsrb-reason {
  margin: 0 0 12px;
  padding: 10px 12px;
  border: 1px solid var(--dsw-alias-border-l1);
  border-radius: 10px;
  background: var(--dsw-alias-bg-layer-1);
  color: var(--dsw-alias-state-error-primary);
  font-size: 13px;
  line-height: 1.6;
  word-break: break-word;
}
.dsrb-detail {
  margin: 0 0 12px;
  padding: 10px 12px;
  max-height: 220px;
  overflow: auto;
  border: 1px solid var(--dsw-alias-border-l1);
  border-radius: 10px;
  background: var(--dsw-alias-bg-layer-1);
  color: var(--dsw-alias-label-secondary);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px;
  line-height: 1.55;
  white-space: pre-wrap;
  word-break: break-word;
}
.dsrb-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: 8px;
}
.dsrb-btn {
  height: 32px;
  padding: 0 14px;
  border: 1px solid var(--dsw-alias-border-l1);
  border-radius: 8px;
  background: transparent;
  color: var(--dsw-alias-label-primary);
  font: inherit;
  font-size: 13px;
  line-height: 1;
  cursor: pointer;
}
.dsrb-btn:hover { background: var(--dsw-alias-bg-layer-2); }
.dsrb-btn:focus-visible { outline: 2px solid var(--dsw-alias-brand-primary); outline-offset: 1px; }
.dsrb-btn-primary {
  border-color: transparent;
  /* 实心强调按钮：底色固定为强调蓝 + 白字。
     实测本机主题的 --dsw-alias-brand-primary 是浅色，用它做底色会出现白底白字；
     这里不依赖主题色，保证任何主题下都读得清。 */
  background: #2f6feb;
  color: #ffffff;
  font-weight: 600;
}
.dsrb-btn-primary:hover { background: #3b7bf5; }
.dsrb-btn-primary:disabled { opacity: .65; cursor: not-allowed; }
.dsrb-btn-ghost {
  margin-right: auto;
  border-color: transparent;
  color: var(--dsw-alias-label-secondary);
}
.dsrb-btn-ghost:hover { color: var(--dsw-alias-label-primary); }
`;

    /** 重启图标（圆环 + 箭头），跟随 currentColor。 */
    function RestartGlyph({ spinning }) {
      return h('svg', {
        className: spinning ? 'dsrb-foot-icon dsrb-foot-spin' : 'dsrb-foot-icon',
        viewBox: '0 0 24 24',
        'aria-hidden': true,
        focusable: false,
      },
      h('path', {
        d: 'M20 12a8 8 0 1 1-2.34-5.66',
        fill: 'none',
        stroke: 'currentColor',
        strokeWidth: 2,
        strokeLinecap: 'round',
      }),
      h('path', {
        d: 'M20 4v5h-5',
        fill: 'none',
        stroke: 'currentColor',
        strokeWidth: 2,
        strokeLinecap: 'round',
        strokeLinejoin: 'round',
      }));
    }

    /** 读 JSON，非 2xx 也把响应体解析出来，便于展示服务端给的原因。 */
    async function requestJson(url, init) {
      const response = await fetch(url, { cache: 'no-store', ...init });
      let payload = null;
      try {
        payload = await response.json();
      } catch {
        payload = null;
      }
      return { ok: response.ok, status: response.status, payload };
    }

    function apply(ctx) {
      const localeSvc = ctx.get('locale') ?? null;
      const slots = ctx.get('slots') ?? null;

      // 字典注册：zh / en 两套都要给，缺一个注册会抛错
      ctx.effect(() => {
        if (!localeSvc || typeof localeSvc.register !== 'function') return undefined;
        return localeSvc.register(NS, { zh: ZH, en: EN });
      }, 'dsh-restart-button: dictionaries');

      /** 组件内翻译：订阅 locale/change 触发重渲染；服务缺失时查兜底字典。 */
      function useTranslate() {
        const [, force] = useState(0);
        useEffect(() => {
          if (!localeSvc || typeof localeSvc.subscribe !== 'function') return undefined;
          return localeSvc.subscribe(() => force((n) => n + 1));
        }, []);
        return useCallback((key) => {
          if (localeSvc && typeof localeSvc.bind === 'function') {
            try {
              const text = localeSvc.bind(NS)(key);
              // locale 服务未注册本命名空间时会原样返回 key：退回兜底字典。
              if (typeof text === 'string' && text !== '' && text !== key) return text;
            } catch {
              // 落到兜底
            }
          }
          return FALLBACK[key] ?? key;
        }, []);
      }

      // ── 弹窗容器：portal 到 body，避免被侧栏 transform 困住 ──
      // react-dom 在浏览器模块表里；取不到时退回「直接渲染」，至少不白屏。
      const ReactDOM = (() => {
        try {
          return require('react-dom');
        } catch {
          return null;
        }
      })();

      function Portal({ children }) {
        const [host, setHost] = useState(null);
        useEffect(() => {
          const el = document.createElement('div');
          el.setAttribute('data-dsh-restart-button', 'portal');
          document.body.appendChild(el);
          setHost(el);
          return () => {
            if (el.parentNode) el.parentNode.removeChild(el);
          };
        }, []);
        if (!host) return null;
        if (ReactDOM && typeof ReactDOM.createPortal === 'function') {
          return ReactDOM.createPortal(children, host);
        }
        return children;
      }

      /** 通用模态：Escape 关闭、点遮罩关闭、打开时聚焦主按钮。 */
      function Modal({ onClose, labelId, children, dismissable = true }) {
        const ref = useRef(null);
        useEffect(() => {
          const onKey = (event) => {
            if (event.key !== 'Escape' || !dismissable) return;
            event.stopPropagation();
            onClose();
          };
          window.addEventListener('keydown', onKey, true);
          return () => window.removeEventListener('keydown', onKey, true);
        }, [onClose, dismissable]);
        useEffect(() => {
          const node = ref.current;
          if (!node) return;
          const target = node.querySelector('[data-autofocus]') ?? node;
          if (typeof target.focus === 'function') target.focus();
        }, []);
        return h(Portal, null, h('div', {
          className: 'dsrb-scrim',
          onMouseDown: (event) => {
            if (dismissable && event.target === event.currentTarget) onClose();
          },
        }, h('div', {
          ref,
          className: 'dsrb-dialog',
          role: 'dialog',
          'aria-modal': 'true',
          'aria-labelledby': labelId,
          tabIndex: -1,
        }, children)));
      }

      // ── 侧栏几何：按钮要贴在侧栏右下角，坐标必须来自实测而不是猜 ──
      // 侧栏根 div 没有 data 标记，只能从它内部稳定的标记反推：
      //   - 宽态：[data-sidebar-scrollport]（滚动区）
      //   - 折叠态：[data-sidebar-toggle]（展开按钮）
      // 两者都向上找「最近的一个宽度足够、高度接近整窗」的祖先，就是侧栏列。
      // 找不到就返回 null，按钮退回文档流形态（绝不静默消失）。
      let sidebarAnchor = null;
      const sidebarListeners = new Set();

      function publishSidebarAnchor(next) {
        const prev = sidebarAnchor;
        const same = prev === null && next === null
          || prev !== null && next !== null
          && prev.left === next.left && prev.width === next.width
          && prev.bottomInset === next.bottomInset;
        if (same) return;
        sidebarAnchor = next;
        for (const listener of sidebarListeners) listener();
      }

      /**
       * 找到「贴着窗口底部」的侧栏列元素。
       *
       * 踩过的坑（两次实测）：
       * 1) 取「第一个宽度合规的祖先」→ 命中列表容器，按钮飘到会话列表中部；
       * 2) 取「高度最大」仍不够——侧栏内部的滚动容器可能也很高。
       * 所以硬条件改为必须**贴底**：rect.bottom 距窗口底部不超过 80px 才算侧栏列。
       * 这排除了所有中间容器，剩下的就是那条从顶部贯到底部的列。
       */
      function findSidebarColumn() {
        const seeds = [
          document.querySelector('[data-sidebar-scrollport]'),
          document.querySelector('[data-sidebar-toggle]'),
          document.querySelector('[data-sidebar-opener]'),
        ].filter(Boolean);
        const viewportBottom = window.innerHeight;
        let best = null;
        for (const seed of seeds) {
          let node = seed;
          for (let depth = 0; depth < 18 && node !== null; depth += 1) {
            if (node instanceof HTMLElement) {
              const rect = node.getBoundingClientRect();
              const pinnedToBottom = rect.bottom >= viewportBottom - 80;
              const widthOk = rect.width >= 140 && rect.width <= 560;
              if (widthOk && pinnedToBottom && rect.height >= 400) {
                if (best === null || rect.height > best.height) {
                  best = {
                    left: rect.left,
                    width: rect.width,
                    height: rect.height,
                    bottom: rect.bottom,
                  };
                }
              }
            }
            node = node.parentElement;
          }
        }
        return best;
      }

      const measureSidebar = () => {
        const rect = findSidebarColumn();
        if (rect === null) {
          publishSidebarAnchor(null);
          return;
        }
        // 侧栏底线距视口底部的距离（通常就是那点内边距/圆角留白）
        const inset = Math.max(0, Math.round(window.innerHeight - rect.bottom));
        publishSidebarAnchor({
          left: rect.left,
          width: rect.width,
          bottomInset: inset,
        });
      };

      /**
       * 设置面板是否打开。
       *
       * 依据宿主源码 SettingsRoot.tsx：面板根节点上有
       * `data-shortcut-modal="settings"` + `role="dialog" aria-modal="true"`，
       * 关闭时该节点整体卸载。所以直接查这个标记即可，不需要猜样式或层级。
       * 面板打开时按钮必须隐藏——否则重启按钮会浮在设置界面最底层，很突兀。
       */
      function isSettingsOpen() {
        return document.querySelector('[data-shortcut-modal="settings"]') !== null;
      }

      // 设置面板开关状态：与 sidebarAnchor 同款「模块级状态 + 订阅者」模式，
      // 组件通过 useState 订阅它，避免在非组件作用域里用 hook。
      let settingsOpen = false;
      const settingsListeners = new Set();

      function publishSettingsOpen(next) {
        if (settingsOpen === next) return;
        settingsOpen = next;
        for (const listener of settingsListeners) listener();
      }

      const syncSettingsOpen = () => {
        publishSettingsOpen(isSettingsOpen());
      };

      // 主按钮 ──
      function RestartFooterButton() {
        const t = useTranslate();
        const [phase, setPhase] = useState('idle'); // idle | confirm | pending | restarting | error
        const [failure, setFailure] = useState(null);
        const [logText, setLogText] = useState(null);
        const [copied, setCopied] = useState(false);
        // 订阅侧栏几何变化：拖宽、折叠、窗口缩放后按钮要跟着走
        const [anchor, setAnchor] = useState(sidebarAnchor);
        useEffect(() => {
          const listener = () => setAnchor(sidebarAnchor);
          sidebarListeners.add(listener);
          // 挂载时同步一次，避免注册早于首次测量
          listener();
          return () => {
            sidebarListeners.delete(listener);
          };
        }, []);
        // 订阅设置面板开关：打开时整颗按钮不渲染（保存置顶/悬浮的中间态）
        const [settings, setSettings] = useState(settingsOpen);
        useEffect(() => {
          const listener = () => setSettings(settingsOpen);
          settingsListeners.add(listener);
          listener();
          return () => {
            settingsListeners.delete(listener);
          };
        }, []);

        const close = useCallback(() => {
          if (phase === 'restarting') return; // 已经在重启，不允许关掉
          setPhase('idle');
          setFailure(null);
          setLogText(null);
          setCopied(false);
        }, [phase]);

        const start = useCallback(async () => {
          setPhase('pending');
          setFailure(null);
          try {
            const { ok, status, payload } = await requestJson(ENDPOINT.restart, {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: '{}',
            });
            if (ok && payload && payload.ok) {
              setPhase('restarting');
              return;
            }
            // 失败：把服务端原因、状态码都收下来，供错误框展示
            setFailure({
              reason: (payload && payload.error) || `重启请求失败（HTTP ${status}）`,
              detail: (payload && payload.detail) || null,
              status,
            });
            setPhase('error');
            // 顺带取一次日志尾部，排查更省事（取不到不影响错误展示）
            requestJson(ENDPOINT.log).then((result) => {
              if (result.payload && typeof result.payload.text === 'string') setLogText(result.payload.text);
            }).catch(() => {});
          } catch (error) {
            setFailure({
              reason: '无法连接到本地服务，重启没有发出',
              detail: { message: String(error?.message ?? error) },
              status: 0,
            });
            setPhase('error');
          }
        }, []);

        const copyLog = useCallback(async () => {
          const text = logText ?? '';
          try {
            await navigator.clipboard.writeText(text);
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1600);
          } catch {
            setCopied(false);
          }
        }, [logText]);

        const label = t('button.label');
        // 定位说明：宿主把 sidebar.footer.action 渲染在 .footerActions（品牌行上方），
        // 与需求位置（侧栏最底部、账号头像右侧）不一致。
        //
        // 这里必须走 Portal 挂到 body 再 fixed：侧栏链路上有带 transform 的祖先
        // （折叠动画会加 transform），一旦在那种祖先内部，fixed 会以该祖先为参照系，
        // 结果就是横向偏左、纵向压在会话列表上（两次实测都栽在这）。
        // 挂到 body 之后坐标才等于视口坐标，跟实测值一致。
        const pinned = anchor !== null;
        // 纵向：bottom 越大越靠上。锚点距侧栏底部 16px，使按钮中线与账号头像对齐
        // （实测 +12 偏下、+20 偏上一点，+16 为最终采用值）。
        const style = pinned ? {
          position: 'fixed',
          left: `${Math.round(anchor.left + anchor.width - 12)}px`,
          bottom: `${anchor.bottomInset + 16}px`,
          transform: 'translateX(-100%)',
          zIndex: 2147481000,
        } : undefined;

        const button = h('button', {
          type: 'button',
          className: pinned ? 'dsrb-foot dsrb-foot-pinned' : 'dsrb-foot',
          style,
          title: t('button.title'),
          'aria-label': t('button.aria'),
          disabled: phase === 'pending' || phase === 'restarting',
          onClick: () => {
            if (phase === 'pending' || phase === 'restarting') return;
            setPhase('confirm');
          },
        },
        h(RestartGlyph, { spinning: phase === 'pending' || phase === 'restarting' }),
        h('span', { className: 'dsrb-foot-label' }, label));
        const overlays = [];

        if (phase === 'confirm') {
          overlays.push(h(Modal, { key: 'confirm', onClose: close, labelId: 'dsrb-confirm-title' },
            h('h2', { className: 'dsrb-title', id: 'dsrb-confirm-title' }, t('confirm.title')),
            h('p', { className: 'dsrb-body' }, t('confirm.body')),
            h('div', { className: 'dsrb-actions' },
              h('button', {
                type: 'button',
                className: 'dsrb-btn',
                onClick: close,
              }, t('confirm.cancel')),
              h('button', {
                type: 'button',
                className: 'dsrb-btn dsrb-btn-primary',
                'data-autofocus': true,
                onClick: start,
              }, t('confirm.ok')))));
        }

        if (phase === 'pending' || phase === 'restarting') {
          overlays.push(h(Modal, {
            key: 'progress',
            onClose: () => {},
            labelId: 'dsrb-progress-title',
            dismissable: false,
          },
          h('h2', { className: 'dsrb-title', id: 'dsrb-progress-title' }, t('progress.title')),
          h('p', { className: 'dsrb-body' }, t('progress.body'))));
        }

        if (phase === 'error') {
          const detailText = (() => {
            if (logText) return logText;
            if (!failure?.detail) return '';
            try {
              return JSON.stringify(failure.detail, null, 2);
            } catch {
              return String(failure.detail);
            }
          })();
          overlays.push(h(Modal, { key: 'error', onClose: close, labelId: 'dsrb-error-title' },
            h('h2', { className: 'dsrb-title', id: 'dsrb-error-title' }, t('error.title')),
            h('p', { className: 'dsrb-reason' }, failure?.reason ?? t('error.title')),
            detailText === '' ? null : h('pre', { className: 'dsrb-detail' }, detailText),
            h('div', { className: 'dsrb-actions' },
              detailText === '' ? null : h('button', {
                type: 'button',
                className: 'dsrb-btn dsrb-btn-ghost',
                onClick: copyLog,
              }, copied ? t('log.copied') : t('log.copy')),
              h('button', { type: 'button', className: 'dsrb-btn', onClick: close }, t('error.close')),
              h('button', {
                type: 'button',
                className: 'dsrb-btn dsrb-btn-primary',
                'data-autofocus': true,
                onClick: start,
              }, t('error.retry')))));
        }

        // 设置面板打开时，按钮整体不渲染（连弹窗也一并收起）。
        // 注意：这里必须放在 overlays 组装之后统一判断，保证面板一打开就干净退出，
        // 不会留半截遮罩在设置界面上面。
        if (settings) return null;

        return h(React.Fragment, null,
          pinned ? h(Portal, null, button) : button,
          ...overlays);
      }

      if (!slots || typeof slots.inject !== 'function') {
        console.warn('[dsh-restart-button] 没有 slots 服务，按钮无法挂载');
        return;
      }

      // 侧栏几何跟踪：窗口尺寸、侧栏拖宽、折叠切换都会改变锚点。
      // 同一处顺带跟踪设置面板开关（按钮在设置里必须隐藏）。
      ctx.effect(() => {
        let frame = 0;
        const schedule = () => {
          if (frame !== 0) return;
          frame = requestAnimationFrame(() => {
            frame = 0;
            measureSidebar();
            syncSettingsOpen();
          });
        };
        // 首帧先量一次
        measureSidebar();
        syncSettingsOpen();
        window.addEventListener('resize', schedule);
        const observer = typeof ResizeObserver === 'function'
          ? new ResizeObserver(schedule)
          : null;
        // 侧栏元素可能晚于本插件挂载：轮询一小段时间直到找到，再交给 observers
        let tries = 0;
        const findTimer = window.setInterval(() => {
          const found = findSidebarColumn() !== null;
          if (found) {
            const scrollport = document.querySelector('[data-sidebar-scrollport]');
            if (scrollport) observer?.observe(scrollport);
            schedule();
            window.clearInterval(findTimer);
            return;
          }
          if (++tries > 60) window.clearInterval(findTimer);
        }, 250);
        // body 子树变化同时覆盖两种情形：侧栏尺寸变化、设置面板挂载/卸载
        const mo = typeof MutationObserver === 'function'
          ? new MutationObserver(schedule)
          : null;
        mo?.observe(document.body, { childList: true, subtree: true });
        return () => {
          window.removeEventListener('resize', schedule);
          window.clearInterval(findTimer);
          if (frame !== 0) cancelAnimationFrame(frame);
          observer?.disconnect();
          mo?.disconnect();
        };
      }, 'dsh-restart-button: sidebar geometry + settings visibility');

      // 惰性 inject：等 sidebar.footer.action 被声明后再注册，避免启动时序导致 fiber 抛错。
      ctx.effect(() => {
        const dispose = slots.inject('sidebar.footer.action', () => slots.register({
          name: 'sidebar.footer.action',
          id: 'dsh-restart-button',
          order: 40,
          locale: NS,
        }, RestartFooterButton));
        return () => {
          if (typeof dispose === 'function') dispose();
        };
      }, 'dsh-restart-button: footer action');

      // 样式随插件生命周期插入/移除
      ctx.effect(() => {
        const style = document.createElement('style');
        style.setAttribute('data-dsh-restart-button', 'style');
        style.textContent = CSS;
        document.head.appendChild(style);
        return () => {
          if (style.parentNode) style.parentNode.removeChild(style);
        };
      }, 'dsh-restart-button: styles');
    }

    return {
      inject: ['slots', 'locale'],
      apply,
    };
  },
});
