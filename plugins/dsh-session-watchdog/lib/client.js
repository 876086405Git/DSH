/**
 * 会话哨兵（dsh-session-watchdog）· 浏览器半侧
 *
 * 唯一职责：把宿主半侧记录的「会话异常停止」变成用户能看见、能操作的提醒。
 *   1. 轮询宿主 alerts 路由（可见 1500ms / 后台 5000ms），按 id 去重并推进 cursor；
 *   2. 右上角浮层卡片：会话标题 / 原因中文标签 / 错误摘要 / 时间 +「续跑」「忽略」；
 *   3. 侧栏会话行尾徽标（官方槽 sidebar.session.row.trailing）：红=异常、黄=续跑中、绿=已恢复；
 *   4. 页面在后台且 config.notifyOs 时发 Web Notification，点击跳回对应会话；
 *   5. 设置页整页（官方槽 settings.section，order 510）：提醒开关 / 监控规则 / 监控范围 / 阈值预算，
 *      直接读写宿主 /dsh-session-watchdog/config，保存后即时生效（无需重启）。
 *
 * 模块形态（已核实）：浏览器插件不是 ESM，必须用 window.__ModuleLoader__.load 注册工厂。
 *   出处：research/02-ui-alert.md:386-400（§2.3 客户端 bundle 的物理形态）
 *   模块体副作用是延迟的（首次 materialize 才执行），所以顶层只注册工厂、不碰 DOM。
 *   出处：research/02-ui-alert.md:403、:1036（§6.3 坑 8）
 *
 * 依赖的宿主 API（逐条标注出处）：
 *   - window.__ModuleLoader__.load({ id, factory })           02-ui-alert.md:388-400
 *   - exports.inject = ['uiSession']（Cordis 服务名）          02-ui-alert.md:394、:403-405
 *   - ctx.inject(['uiSession'], cb) 晚到兜底                    REFS/99galaxy.../client.js:843-853
 *   - ctx.get(name)（无 inject 要求地取服务）                  asar cordis/lib/index.js:1339-1356
 *   - ctx.effect(fn, label) 生命周期清理                       asar cordis/lib/index.js:463
 *   - ctx.slots.inject(name, cb) / ctx.slots.register(...)     02-ui-alert.md:411-412、:430
 *   - 槽 sidebar.session.row.trailing                         02-ui-alert.md:250-254、:257-267
 *   - ctx.uiWorkspace.openSession(sessionId)                  02-ui-alert.md:957-975
 *   - new Notification(title, { body, tag })                  02-ui-alert.md:825-848
 *   - 宿主 HTTP 路由（fetch 相对路径）                         02-ui-alert.md:560、:605
 *
 * 边界（报告核实过，不要越过）：
 *   - 宿主是独立 Node 进程，require('electron') 必失败            02-ui-alert.md:727-747
 *   - 往 Electron main 发 IPC 会被判非法并 SIGTERM 宿主            02-ui-alert.md:749-779
 *   - 槽不可用时**不猜 DOM**（v1 允许只有提醒卡片）—— task-4 要求 4
 *   - 全文件不 import 任何 @deepseek-ai/*，不引外部依赖
 */
if (typeof window !== 'undefined' && window.__ModuleLoader__ && typeof window.__ModuleLoader__.load === 'function') {
  try {
    window.__ModuleLoader__.load({
      // 模块系统的 row id 必须等于 package name。出处：02-ui-alert.md:388-400
      id: 'dsh-session-watchdog',
      factory: (require) => {
        const module = { exports: {} };
        const exports = module.exports;
        try {
          Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
        } catch (error) {
          /* 老引擎不支持 Symbol.toStringTag，忽略 */
        }

        // Cordis 服务名列表（不是包 id 预载边）。出处：02-ui-alert.md:394、:1029（§6.3 坑 1）
        const inject = ['uiSession'];

        // ────────────────────────────────────────────────────────────────────
        // 常量（路由与字段形状来自 Lead 定下的宿主契约，禁止自行改动）
        // ────────────────────────────────────────────────────────────────────
        const NS = 'dsh-session-watchdog';
        const CONFIG_URL = '/dsh-session-watchdog/config';
        const ALERTS_URL = '/dsh-session-watchdog/alerts';
        const ACTION_URL = '/dsh-session-watchdog/action';

        /** 侧栏行尾槽名（list / inline）。出处：02-ui-alert.md:250-254、:257-267 */
        const BADGE_SLOT = 'sidebar.session.row.trailing';

        /** 轮询节奏：可见 1500ms、后台 5000ms（task-4 要求 2） */
        const POLL_VISIBLE_MS = 1500;
        const POLL_HIDDEN_MS = 5000;
        /** 请求失败后的指数退避：1.5s → 3s → 6s → 12s → 24s → 封顶 30s */
        const MAX_BACKOFF_MS = 30000;
        const MAX_BACKOFF_STEPS = 5;
        /** 单次请求超时，避免慢请求把轮询拖死 */
        const FETCH_TIMEOUT_MS = 8000;
        /** 配置没拿到时的重试间隔 */
        const CONFIG_RETRY_MS = 15000;

        /** 提醒卡片：最多同时 4 张，超出排队（task-4 要求 3） */
        const MAX_CARDS = 4;
        const MAX_QUEUE = 20;
        const CARD_WIDTH = 320;
        /** 「已恢复」绿点保留时长，避免一闪而过 */
        const BADGE_RESUMED_TTL_MS = 30000;

        /** 宿主契约里的配置默认值（拿到路由响应后覆盖；与 lib/policy.js:9-42 的 DEFAULT_CONFIG 对齐） */
        const DEFAULT_CONFIG = {
          notifyOs: true,
          notifyGui: true,
          toastDurationMs: 8000,
          notifyOnCompletion: true,
          completionSound: 'dingdong',
          completionVolume: 70,
          resumePromptMode: 'llm',
        };

        /** kind → 中文标签（宿主契约枚举：error/interrupted/max-tokens/blocked/stalled/completed） */
        const KIND_LABEL = {
          error: '运行出错',
          interrupted: '意外中断',
          'max-tokens': '达到 Token 上限',
          blocked: '等待交互',
          stalled: '疑似卡住',
          completed: '任务完成',
        };

        /** 完成提示音候选（首项 none = 关闭），顺序与宿主 lib/policy.js:45 的 COMPLETION_SOUNDS 一致 */
        const COMPLETION_SOUNDS = ['none', 'dingdong', 'double', 'tritone', 'drop', 'chime', 'pulse'];
        const COMPLETION_SOUND_LABEL = {
          none: '关闭',
          dingdong: '叮咚（双音）',
          double: '清脆双击',
          tritone: '轻快三连音',
          drop: '水滴下滑音',
          chime: '柔和小铃',
          pulse: '电子脉冲',
        };

        /** 续跑指令生成方式（与宿主 lib/policy.js:48 的 RESUME_PROMPT_MODES 一致） */
        const RESUME_PROMPT_MODES = ['llm', 'context'];
        const RESUME_PROMPT_MODE_LABEL = {
          llm: '模型依据会话内容生成',
          context: '上下文摘录拼装',
        };

        /** 下拉选项（字段元数据直接引用，避免重复写字面量） */
        const COMPLETION_SOUND_OPTIONS = COMPLETION_SOUNDS.map((value) => ({
          value: value,
          label: COMPLETION_SOUND_LABEL[value] || value,
        }));
        const RESUME_PROMPT_MODE_OPTIONS = RESUME_PROMPT_MODES.map((value) => ({
          value: value,
          label: RESUME_PROMPT_MODE_LABEL[value] || value,
        }));

        /** stage → 中文标签（宿主契约枚举：detected/resuming/resumed/resume-failed/notified） */
        const STAGE_LABEL = {
          detected: '已检测',
          resuming: '续跑中',
          resumed: '已恢复',
          'resume-failed': '续跑失败',
          notified: '已提醒',
        };

        /** 徽标三色：异常=红、续跑中=黄、已恢复=绿（task-4 要求 4） */
        const LEVEL_COLOR = { error: '#ef4444', resuming: '#f59e0b', resumed: '#22c55e' };
        const LEVEL_LABEL = { error: '异常', resuming: '续跑中', resumed: '已恢复' };

        // ────────────────────────────────────────────────────────────────────
        // 设置面板：字段元数据与纯函数（不含 UI）
        //   槽清单：research/02-ui-alert.md:885-898（§4.1；settings.section 是 list 槽，条目需 id+order+label）
        //   注册模式：research/02-ui-alert.md:465-495（§2.6 可抄代码；dsh-checkup 的 settings.section order 510）
        //   字段白名单：lib/config-store.js:12-35（EDITABLE_FIELDS，宿主只接受这些字段）
        //   默认值来源：lib/policy.js:9-35（DEFAULT_CONFIG；毫秒字段在面板里按秒展示）
        // ────────────────────────────────────────────────────────────────────

        /** 设置页槽名与条目参数。出处：02-ui-alert.md:892（settings.section，order 510） */
        const SETTINGS_SLOT = 'settings.section';
        const SETTINGS_ENTRY_ID = 'dsh-session-watchdog-settings';
        const SETTINGS_ORDER = 510;

        /** 续跑原因枚举（顺序固定，宿主 policy 只认这四个）。出处：lib/policy.js:12、:169 */
        const RESUME_KINDS = ['error', 'interrupted', 'max-tokens', 'blocked'];

        /** 把任意异常转成可读的一句话（设置面板错误提示用）。 */
        function errorMessage(error) {
          try {
            if (error && typeof error.message === 'string' && error.message !== '') return error.message;
            if (typeof error === 'string' && error !== '') return error;
            const text = String(error);
            return text === '[object Object]' ? '未知错误' : text;
          } catch (nested) {
            return '未知错误';
          }
        }

        /**
         * 四组设置（顺序即渲染顺序）。
         * type：bool 布尔 | number 数字 | ms 毫秒（面板显示秒，提交乘 1000） | list 字符串数组 | kinds 续跑原因多选
         */
        const SETTINGS_GROUPS = [
          {
            id: 'alerts',
            title: 'A. 提醒开关',
            hint: '会话异常停止时，用哪种方式提醒你。',
            fields: [
              {
                key: 'notifyGui',
                type: 'bool',
                label: '页面提醒',
                hint: '在页面右上角弹出提醒卡片，带「续跑」「忽略」按钮。',
              },
              {
                key: 'notifyOs',
                type: 'bool',
                label: '系统通知',
                hint: '页面在后台时发系统通知，点击可跳回对应会话。',
              },
              {
                key: 'notifyOnCompletion',
                type: 'bool',
                label: '任务完成也提醒',
                hint: '会话正常跑完时也弹提醒（完成提醒只有「忽略」按钮，不会续跑）。',
              },
              {
                key: 'completionSound',
                type: 'select',
                label: '完成提示音',
                hint: '任务完成时播放的提示音；浏览器不允许音频时静默跳过，不影响提醒卡片。',
                options: COMPLETION_SOUND_OPTIONS,
                defaultValue: 'dingdong',
                preview: true,
              },
              {
                key: 'completionVolume',
                type: 'number',
                label: '提示音音量（0-100）',
                hint: '0 等于静音；与系统音量叠加。',
                min: 0,
                max: 100,
              },
              {
                key: 'notifyOnAborted',
                type: 'bool',
                label: '用户主动停止也提醒',
                hint: '你自己点「停止」时是否也提醒；默认关闭以免打扰。',
              },
              {
                key: 'notifyOnStall',
                type: 'bool',
                label: '假死提醒',
                hint: '会话长时间没有任何事件时提醒。',
              },
              {
                key: 'toastDurationMs',
                type: 'ms',
                label: '卡片停留（秒）',
                hint: '提醒卡片自动关闭前停留的秒数。',
              },
            ],
          },
          {
            id: 'rules',
            title: 'B. 监控内容规则',
            hint: '哪些停止原因要监控、要不要自动续跑。',
            fields: [
              {
                key: 'enabled',
                type: 'bool',
                label: '总开关',
                hint: '关闭后哨兵完全不工作（不检测、不提醒、不续跑）。',
              },
              {
                key: 'autoResume',
                type: 'bool',
                label: '自动续跑',
                hint: '检测到异常停止后自动发一条续跑指令。',
              },
              {
                key: 'resumePromptMode',
                type: 'select',
                label: '续跑指令生成方式',
                hint: '「模型依据会话内容生成」会消耗少量 token；调用失败时自动回落到「上下文摘录拼装」。',
                options: RESUME_PROMPT_MODE_OPTIONS,
                defaultValue: 'llm',
              },
              {
                key: 'monitorSubagents',
                type: 'bool',
                label: '监控子代理',
                hint: '子代理会话异常停止时也提醒并续跑。',
              },
              {
                key: 'skipWhenAwaitingUser',
                type: 'bool',
                label: '等待用户审批时暂停续跑',
                hint: '会话正在等你输入或审批时不要自动续跑。',
              },
              {
                key: 'resumeOnStartupScan',
                type: 'bool',
                label: '启动扫描历史会话自动续跑',
                hint: 'DSH 启动时补扫上次未闭合的会话并自动续跑。',
              },
              {
                key: 'resumeOnStall',
                type: 'bool',
                label: '假死也自动续跑',
                hint: '判定为假死时是否自动续跑；关闭则只提醒。',
              },
              {
                key: 'resumeKinds',
                type: 'kinds',
                label: '续跑原因（多选）',
                hint: '只有勾选的停止原因才会自动续跑；假死由上面一项单独控制。',
              },
            ],
          },
          {
            id: 'scope',
            title: 'C. 监控范围',
            hint: '目录按前缀匹配，留空 = 全部；支持 Windows 路径（例如 D:\\work\\proj）。',
            fields: [
              {
                key: 'includeCwd',
                type: 'list',
                label: '包含目录',
                hint: '只监控这些目录下的会话；留空表示不限制。',
                placeholder: '例如 D:\\work\\my-project',
              },
              {
                key: 'excludeCwd',
                type: 'list',
                label: '排除目录',
                hint: '这些目录下的会话一律不监控。',
                placeholder: '例如 D:\\work\\scratch',
              },
              {
                key: 'excludeSessionIds',
                type: 'list',
                label: '排除会话',
                hint: '按会话 id 精确排除。',
                placeholder: '输入会话 id 后点「添加」',
              },
            ],
          },
          {
            id: 'limits',
            title: 'D. 阈值与预算',
            hint: '控制判定时机与自动续跑的额度。',
            fields: [
              {
                key: 'stallTimeoutMs',
                type: 'ms',
                label: '假死阈值（秒）',
                hint: '超过这个时长没有任何事件就判定为假死。',
              },
              {
                key: 'toolStallTimeoutMs',
                type: 'ms',
                label: '工具宽限（秒）',
                hint: '工具调用期间额外放宽的时长。',
              },
              {
                key: 'resumeDelayMs',
                type: 'ms',
                label: '续跑延时（秒）',
                hint: '判定停止后等待多久再发续跑指令。',
              },
              {
                key: 'maxResumesPerSession',
                type: 'number',
                label: '每会话续跑上限',
                hint: '同一会话最多自动续跑几次。',
              },
              {
                key: 'globalBudget',
                type: 'number',
                label: '全局预算',
                hint: '所有会话合计最多自动续跑几次。',
              },
              {
                key: 'maxConsecutiveFailures',
                type: 'number',
                label: '连续失败熔断',
                hint: '连续失败达到这个次数后停止自动续跑。',
              },
              {
                key: 'maxContextChars',
                type: 'number',
                label: '指令长度上限（字符）',
                hint: '续跑指令最多携带多少字符的上下文。',
              },
            ],
          },
        ];

        /** 扁平字段表（顺序 = 面板顺序）。 */
        const SETTINGS_FIELDS = SETTINGS_GROUPS.reduce((all, group) => all.concat(group.fields), []);

        /** 按 key 取字段元数据（渲染「试听」按钮时要用 completionSound / completionVolume）。 */
        const FIELD_BY_KEY = SETTINGS_FIELDS.reduce((map, field) => {
          map[field.key] = field;
          return map;
        }, {});

        /** 下拉字段取值：值不在候选里（脏数据/旧配置）时回落字段默认项，绝不抛错。 */
        function normalizeSelectValue(field, value) {
          const text = typeof value === 'string' ? value : '';
          if (field && Array.isArray(field.options)) {
            for (const option of field.options) {
              if (option && option.value === text) return text;
            }
            if (text === '' && typeof field.defaultValue === 'string') return field.defaultValue;
            return typeof field.defaultValue === 'string' ? field.defaultValue : '';
          }
          return text;
        }

        /** 数字字段钳制：只有声明了 min/max 的字段才钳制（其余字段保持原有「非负」校验）。 */
        function clampFieldNumber(field, num) {
          let value = Math.round(num);
          if (field && typeof field.min === 'number' && value < field.min) value = field.min;
          if (field && typeof field.max === 'number' && value > field.max) value = field.max;
          return value;
        }

        /** 只保留字符串数组（任何脏输入都不抛）。 */
        function toStringList(value) {
          if (!Array.isArray(value)) return [];
          const out = [];
          for (const item of value) {
            if (typeof item === 'string') out.push(item);
            else if (typeof item === 'number' && Number.isFinite(item)) out.push(String(item));
          }
          return out;
        }

        /** 宿主配置值 → 面板值（毫秒字段转成秒文本；数组只保留字符串）。 */
        function panelValueOf(field, raw) {
          if (field.type === 'bool') return raw === true;
          if (field.type === 'kinds') {
            const list = toStringList(raw);
            return RESUME_KINDS.filter((kind) => list.indexOf(kind) >= 0);
          }
          if (field.type === 'list') return toStringList(raw);
          if (field.type === 'select') return normalizeSelectValue(field, raw);
          if (field.type === 'ms') {
            const ms = Number(raw);
            if (!Number.isFinite(ms) || ms < 0) return '';
            return String(Math.round(ms / 1000));
          }
          const num = Number(raw);
          if (!Number.isFinite(num)) return '';
          if (typeof field.min === 'number' || typeof field.max === 'number') return String(clampFieldNumber(field, num));
          return String(num);
        }

        /** 整份宿主配置 → 面板值对象。 */
        function panelFromConfig(config) {
          const source = config && typeof config === 'object' ? config : {};
          const out = {};
          for (const field of SETTINGS_FIELDS) out[field.key] = panelValueOf(field, source[field.key]);
          return out;
        }

        /** 面板里的数字文本 → 提交值（毫秒字段乘 1000，带 min/max 的字段钳制）；非法返回 null。 */
        function submitValueOfNumber(field, text) {
          const raw = typeof text === 'string' ? text.trim() : String(text === undefined || text === null ? '' : text).trim();
          if (raw === '') return null;
          const num = Number(raw);
          if (!Number.isFinite(num)) return null;
          if (field.type === 'ms') {
            if (num < 0) return null;
            return Math.round(num * 1000);
          }
          if (typeof field.min === 'number' || typeof field.max === 'number') return clampFieldNumber(field, num);
          if (num < 0) return null;
          return Math.round(num);
        }

        /** 字段是否可写：宿主没给 editable（老版本）时按全可写处理。 */
        function isFieldEditable(editable, key) {
          if (!Array.isArray(editable) || editable.length === 0) return true;
          return editable.indexOf(key) >= 0;
        }

        /**
         * 只收集改动过的字段（保存时 POST 的 patch）。
         * 返回 { patch, invalidLabels, count }；count 含非法改动，用于「待提交 n 项」。
         */
        function buildSettingsPatch(form, initial, editable) {
          const patch = {};
          const invalidLabels = [];
          let count = 0;
          if (!form || !initial) return { patch: patch, invalidLabels: invalidLabels, count: 0 };
          for (const field of SETTINGS_FIELDS) {
            if (!isFieldEditable(editable, field.key)) continue;
            const current = form[field.key];
            const before = initial[field.key];
            if (field.type === 'bool') {
              const value = current === true;
              if (value !== (before === true)) {
                patch[field.key] = value;
                count += 1;
              }
              continue;
            }
            if (field.type === 'list' || field.type === 'kinds') {
              const list = toStringList(current);
              const old = toStringList(before);
              if (JSON.stringify(list) !== JSON.stringify(old)) {
                patch[field.key] = list.slice();
                count += 1;
              }
              continue;
            }
            if (field.type === 'select') {
              const value = normalizeSelectValue(field, current);
              const old = normalizeSelectValue(field, before);
              if (value !== old) {
                patch[field.key] = value;
                count += 1;
              }
              continue;
            }
            const text = typeof current === 'string' ? current : current === undefined || current === null ? '' : String(current);
            const oldText = typeof before === 'string' ? before : before === undefined || before === null ? '' : String(before);
            if (text.trim() === oldText.trim()) continue;
            const value = submitValueOfNumber(field, text);
            if (value === null) {
              invalidLabels.push(field.label);
              count += 1;
              continue;
            }
            patch[field.key] = value;
            count += 1;
          }
          return { patch: patch, invalidLabels: invalidLabels, count: count };
        }

        /** 是否偏好暗色（跟随系统 / DSH 主题）。不支持的浏览器返回 false。 */
        function readPrefersDark() {
          try {
            if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
            const query = window.matchMedia('(prefers-color-scheme: dark)');
            return Boolean(query && query.matches === true);
          } catch (error) {
            return false;
          }
        }

        /** 设置面板配色：默认浅色（与 DSH 主题无关），暗色跟随 prefers-color-scheme。 */
        const SETTINGS_PALETTE_LIGHT = {
          bg: '#ffffff',
          text: '#1f2937',
          muted: '#6b7280',
          border: '#e5e7eb',
          divider: '#f1f5f9',
          inputBg: '#ffffff',
          inputBorder: '#d1d5db',
          chipBg: '#eff6ff',
          chipBorder: '#bfdbfe',
          chipText: '#1d4ed8',
          primary: '#2563eb',
          primaryText: '#ffffff',
          success: '#15803d',
          danger: '#dc2626',
        };
        const SETTINGS_PALETTE_DARK = {
          bg: '#1f1f23',
          text: '#e4e4e7',
          muted: '#a1a1aa',
          border: '#3f3f46',
          divider: '#2a2a30',
          inputBg: '#27272a',
          inputBorder: '#52525b',
          chipBg: 'rgba(37,99,235,.18)',
          chipBorder: 'rgba(96,165,250,.5)',
          chipText: '#bfdbfe',
          primary: '#3b82f6',
          primaryText: '#ffffff',
          success: '#4ade80',
          danger: '#f87171',
        };

        // ────────────────────────────────────────────────────────────────────
        // 通用小工具（全部防御式：任何输入都不抛错）
        // ────────────────────────────────────────────────────────────────────

        /** 统一日志出口：控制台不可用时也不能抛。 */
        function warn(...args) {
          try {
            if (typeof console === 'undefined') return;
            if (typeof console.warn === 'function') console.warn('[' + NS + ']', ...args);
            else if (typeof console.log === 'function') console.log('[' + NS + ']', ...args);
          } catch (error) {
            /* 控制台被禁用：静默 */
          }
        }

        /** 截断文本，超长加省略号。 */
        function truncateText(text, max) {
          let value = '';
          try {
            if (typeof text === 'string') value = text;
            else if (text === undefined || text === null) value = '';
            else value = String(text);
          } catch (error) {
            value = '';
          }
          if (value.length <= max) return value;
          const keep = max > 1 ? max - 1 : max;
          return value.slice(0, keep) + '…';
        }

        /** 时间戳 → 本地 HH:MM:SS；坏输入返回空串。 */
        function formatClock(timestamp) {
          try {
            const date = new Date(timestamp);
            if (Number.isNaN(date.getTime())) return '';
            const pad = (value) => (value < 10 ? '0' + value : String(value));
            return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
          } catch (error) {
            return '';
          }
        }

        /** kind 的中文标签；未知值原样显示。 */
        function kindLabel(kind) {
          if (typeof kind === 'string' && Object.prototype.hasOwnProperty.call(KIND_LABEL, kind)) return KIND_LABEL[kind];
          return typeof kind === 'string' && kind !== '' ? kind : '异常停止';
        }

        /** stage 的中文标签；未知值不显示。 */
        function stageLabel(stage) {
          if (typeof stage === 'string' && Object.prototype.hasOwnProperty.call(STAGE_LABEL, stage)) return STAGE_LABEL[stage];
          return '';
        }

        /** 从 alert 里挑一句最能说明问题的文字（summary > reason > error）。 */
        function describeAlert(alert) {
          try {
            const candidates = [alert.summary, alert.reason, alert.error];
            for (const candidate of candidates) {
              if (typeof candidate === 'string' && candidate.trim() !== '') return truncateText(candidate.trim(), 240);
            }
          } catch (error) {
            /* 落到兜底文案 */
          }
          return '（宿主未提供更多细节）';
        }

        /** 卡片第二行：原因中文标签 · 阶段 · 轮次 · 续跑次数（任务完成只显示「任务完成」+ 轮次）。 */
        function metaTextOf(alert) {
          try {
            if (alert && alert.kind === 'completed') {
              const bits = ['任务完成'];
              if (typeof alert.turn === 'number') bits.push('第 ' + alert.turn + ' 轮');
              return bits.join(' · ');
            }
            const bits = [kindLabel(alert.kind)];
            const stageText = stageLabel(alert.stage);
            if (stageText !== '') bits.push(stageText);
            if (typeof alert.turn === 'number') bits.push('第 ' + alert.turn + ' 轮');
            if (typeof alert.resumeCount === 'number' && alert.resumeCount > 0) bits.push('已续跑 ' + alert.resumeCount + ' 次');
            return bits.join(' · ');
          } catch (error) {
            return kindLabel(alert && alert.kind);
          }
        }

        /** 徽标等级：黄（续跑中）> 绿（已恢复/任务完成）> 红（异常/续跑失败/其余）。 */
        function levelOf(alert) {
          if (alert && alert.kind === 'completed') return 'resumed';
          if (alert.stage === 'resuming') return 'resuming';
          if (alert.stage === 'resumed') return 'resumed';
          return 'error';
        }

        /** 徽标悬停/无障碍文案：完成提醒用「任务已完成」，其余沿用异常/续跑语义。 */
        function badgeLabelOf(alert) {
          const level = levelOf(alert);
          if (alert && alert.kind === 'completed') return '会话哨兵：任务已完成';
          return '会话哨兵：' + (LEVEL_LABEL[level] || '异常') + '（' + kindLabel(alert && alert.kind) + '）';
        }

        /** document.hidden 的安全读取（SSR / 无 document 环境返回 false）。 */
        function documentIsHidden() {
          try {
            return typeof document !== 'undefined' && document.hidden === true;
          } catch (error) {
            return false;
          }
        }

        /**
         * 从上下文里取一个 Cordis 服务。
         * ctx.get(name) 是「不要求 inject 就能读」的官方通道。出处：asar cordis/lib/index.js:1339-1356
         */
        function readService(ctxLike, name) {
          if (!ctxLike) return null;
          try {
            if (typeof ctxLike.get === 'function') {
              const value = ctxLike.get(name);
              if (value !== undefined && value !== null) return value;
            }
          } catch (error) {
            /* 未注入的服务读取会抛错，走属性直取 */
          }
          try {
            const value = ctxLike[name];
            if (value !== undefined && value !== null) return value;
          } catch (error) {
            /* 服务不存在：返回 null */
          }
          return null;
        }

        /**
         * fetch 包一层超时；网络/abort 的异常原样抛给调用方（调用方各自 catch）。
         * 路由相对路径能同时命中桌面端（dsh-app://app 转发给宿主）与 Web 端同源。
         * 出处：02-ui-alert.md:560（turn-notify 用 fetch('/dsh-turn-notify/config')）、:605
         */
        function fetchWithTimeout(url, options) {
          if (typeof fetch !== 'function') return Promise.resolve(null);
          const init = Object.assign({ cache: 'no-store', headers: { accept: 'application/json' } }, options);
          let timer;
          let controller;
          try {
            if (typeof AbortController === 'function') {
              controller = new AbortController();
              timer = setTimeout(() => {
                try {
                  controller.abort();
                } catch (error) {
                  /* 已结束 */
                }
              }, FETCH_TIMEOUT_MS);
              init.signal = controller.signal;
            }
          } catch (error) {
            controller = undefined;
            timer = undefined;
          }
          const cleanup = () => {
            if (timer === undefined) return;
            try {
              clearTimeout(timer);
            } catch (error) {
              /* 忽略 */
            }
            timer = undefined;
          };
          return fetch(url, init).then(
            (response) => {
              cleanup();
              return response;
            },
            (error) => {
              cleanup();
              throw error;
            },
          );
        }

        /** 卡片上的按钮统一样式（inline，不注入全局 CSS，卸载时零残留）。 */
        function styleButton(button, primary) {
          try {
            Object.assign(button.style, {
              appearance: 'none',
              WebkitAppearance: 'none',
              border: '1px solid ' + (primary ? 'rgba(96,165,250,.65)' : 'rgba(255,255,255,.18)'),
              background: primary ? 'rgba(59,130,246,.22)' : 'transparent',
              color: primary ? '#bfdbfe' : '#d4d4d8',
              borderRadius: '6px',
              padding: '3px 10px',
              fontSize: '12px',
              lineHeight: '18px',
              fontFamily: 'inherit',
              cursor: 'pointer',
              flex: 'none',
            });
          } catch (error) {
            /* 样式失败不影响功能 */
          }
        }

        // ────────────────────────────────────────────────────────────────────
        // 完成提示音引擎（Web Audio API 合成）
        //   零音频文件、零外部依赖：每种音色 = 若干 oscillator + gain 包络。
        //   设计红线：AudioContext 缺失 / 创建失败 / 被自动播放策略挂起时静默返回 false，
        //   绝不抛错、绝不影响提醒卡片与设置面板。
        // ────────────────────────────────────────────────────────────────────

        /** 6 种音色的合成脚本（at=相对起点秒，dur=持续秒，freq=Hz，gain=峰值增益，freqTo=下滑目标频率）。 */
        const SOUND_SCORES = {
          // 经典叮咚：E5 → C5 两个柔和正弦音
          dingdong: [
            { at: 0, freq: 659.25, dur: 0.42, type: 'sine', gain: 0.22 },
            { at: 0.16, freq: 523.25, dur: 0.58, type: 'sine', gain: 0.2 },
          ],
          // 清脆双击：两下短促的三角波
          double: [
            { at: 0, freq: 1567.98, dur: 0.12, type: 'triangle', gain: 0.18 },
            { at: 0.16, freq: 1567.98, dur: 0.16, type: 'triangle', gain: 0.16 },
          ],
          // 轻快三连音：C5 → E5 → G5
          tritone: [
            { at: 0, freq: 523.25, dur: 0.09, type: 'sine', gain: 0.2 },
            { at: 0.11, freq: 659.25, dur: 0.09, type: 'sine', gain: 0.2 },
            { at: 0.22, freq: 783.99, dur: 0.11, type: 'sine', gain: 0.2 },
          ],
          // 水滴下滑音：1200Hz 指数滑到 320Hz
          drop: [
            { at: 0, freq: 1200, freqTo: 320, dur: 0.5, type: 'sine', gain: 0.24 },
          ],
          // 柔和小铃：基音 + 两个泛音同时衰减
          chime: [
            { at: 0, freq: 880, dur: 0.9, type: 'sine', gain: 0.16 },
            { at: 0.01, freq: 1320, dur: 0.7, type: 'sine', gain: 0.09 },
            { at: 0.02, freq: 1760, dur: 0.5, type: 'sine', gain: 0.06 },
          ],
          // 电子脉冲：三声方波短促脉冲
          pulse: [
            { at: 0, freq: 440, dur: 0.08, type: 'square', gain: 0.12 },
            { at: 0.13, freq: 440, dur: 0.08, type: 'square', gain: 0.12 },
            { at: 0.26, freq: 660, dur: 0.12, type: 'square', gain: 0.12 },
          ],
        };

        /** 创建一份提示音引擎（懒建 AudioContext；所有方法都不抛错）。 */
        function createSoundEngine() {
          const engine = {
            ctx: null,
            failed: false,
            plays: 0,
            lastSound: '',
            lastVolume: 0,
            lastError: '',
            lastPlayedAt: 0,
          };

          /** 取 AudioContext 构造器（拿不到返回 null，含 webkit 前缀）。 */
          function audioContextCtor() {
            try {
              if (typeof window === 'undefined') return null;
              const ctor = window.AudioContext || window.webkitAudioContext;
              return typeof ctor === 'function' ? ctor : null;
            } catch (error) {
              return null;
            }
          }

          /** 懒创建 AudioContext；失败只记一次，之后直接走静默降级。 */
          function ensureContext() {
            if (engine.ctx) return engine.ctx;
            if (engine.failed) return null;
            const Ctor = audioContextCtor();
            if (!Ctor) {
              engine.failed = true;
              return null;
            }
            try {
              engine.ctx = new Ctor();
              return engine.ctx;
            } catch (error) {
              engine.failed = true;
              engine.lastError = 'AudioContext 创建失败：' + errorMessage(error);
              return null;
            }
          }

          /** 尝试 resume 被自动播放策略挂起的上下文；Promise 拒绝也吞掉。 */
          function tryResume(ctx) {
            try {
              if (!ctx || typeof ctx.resume !== 'function') return undefined;
              const result = ctx.resume();
              if (result && typeof result.then === 'function') result.then(() => {}, () => {});
              return result;
            } catch (error) {
              return undefined;
            }
          }

          /** 归一化音量：非数字回落默认值，钳到 0-100。 */
          function normalizeVolume(volume) {
            const num = Number(volume);
            if (!Number.isFinite(num)) return DEFAULT_CONFIG.completionVolume;
            return Math.min(100, Math.max(0, Math.round(num)));
          }

          /** 音色 → 合成脚本；未知音色（含 none）返回 null。 */
          function scoreOf(soundId) {
            if (typeof soundId !== 'string') return null;
            if (!Object.prototype.hasOwnProperty.call(SOUND_SCORES, soundId)) return null;
            const score = SOUND_SCORES[soundId];
            return Array.isArray(score) && score.length > 0 ? score : null;
          }

          /** 给一个音排一条 oscillator + gain 包络；任何一步失败都只是这个音不响。 */
          function scheduleTone(ctx, startAt, tone, masterGain) {
            try {
              const osc = ctx.createOscillator();
              const gain = ctx.createGain();
              if (!osc || !gain) return;
              const at = startAt + (Number.isFinite(tone.at) ? tone.at : 0);
              const dur = Math.min(1.2, Math.max(0.05, Number.isFinite(tone.dur) ? tone.dur : 0.2));
              const peak = Math.min(1, Math.max(0.0001, (Number.isFinite(tone.gain) ? tone.gain : 0.18) * masterGain));
              try {
                osc.type = tone.type || 'sine';
              } catch (error) {
                /* 部分实现不支持该波形：保持默认正弦 */
              }
              const frequency = osc.frequency;
              if (frequency) {
                try {
                  frequency.setValueAtTime(tone.freq, at);
                } catch (error) {
                  try {
                    frequency.value = tone.freq;
                  } catch (nested) {
                    /* 忽略 */
                  }
                }
                if (Number.isFinite(tone.freqTo) && tone.freqTo > 0 && typeof frequency.exponentialRampToValueAtTime === 'function') {
                  try {
                    frequency.exponentialRampToValueAtTime(tone.freqTo, at + dur);
                  } catch (error) {
                    /* 忽略：退化为固定频率 */
                  }
                }
              }
              const envelope = gain.gain;
              if (envelope) {
                try {
                  envelope.setValueAtTime(0.0001, at);
                  const attack = Math.min(0.03, dur / 4);
                  if (typeof envelope.exponentialRampToValueAtTime === 'function') {
                    envelope.exponentialRampToValueAtTime(peak, at + attack);
                    envelope.exponentialRampToValueAtTime(0.0001, at + dur);
                  } else if (typeof envelope.linearRampToValueAtTime === 'function') {
                    envelope.linearRampToValueAtTime(peak, at + attack);
                    envelope.linearRampToValueAtTime(0.0001, at + dur);
                  } else {
                    envelope.setValueAtTime(peak, at + attack);
                  }
                } catch (error) {
                  /* 包络失败：至少保证有声音 */
                }
              }
              try {
                osc.connect(gain);
                gain.connect(ctx.destination);
              } catch (error) {
                /* 连接失败：这个音不响 */
              }
              const stopAt = at + dur + 0.02;
              try {
                osc.start(at);
              } catch (error) {
                /* 忽略 */
              }
              try {
                osc.stop(stopAt);
              } catch (error) {
                /* 忽略 */
              }
            } catch (error) {
              /* 单个音失败不影响其余 */
            }
          }

          /**
           * 播放一个音色。
           * 返回 true = 已排入音频队列；环境不支持 / 被自动播放策略挂起 / 音量 0 / 未知音色返回 false。
           * 任何情况下都不抛错。
           */
          function playSound(soundId, volume) {
            try {
              const score = scoreOf(soundId);
              if (!score) return false;
              const vol = normalizeVolume(volume);
              const ctx = ensureContext();
              if (!ctx) return false;
              // 自动播放策略：上下文被挂起时这一次不发声（下次用户点过页面后由 unlock 恢复）
              if (typeof ctx.state === 'string' && ctx.state !== 'running') {
                tryResume(ctx);
                engine.lastSound = soundId;
                engine.lastVolume = vol;
                engine.lastError = '音频上下文未就绪（' + ctx.state + '）';
                return false;
              }
              const master = vol / 100;
              if (master <= 0) {
                engine.lastSound = soundId;
                engine.lastVolume = vol;
                return false;
              }
              const now = typeof ctx.currentTime === 'number' ? ctx.currentTime + 0.02 : 0.02;
              for (const tone of score) scheduleTone(ctx, now, tone, master);
              engine.plays += 1;
              engine.lastSound = soundId;
              engine.lastVolume = vol;
              engine.lastPlayedAt = Date.now();
              return true;
            } catch (error) {
              engine.lastError = errorMessage(error);
              return false;
            }
          }

          /** 首次用户交互（pointerdown/keydown 一次）时解锁音频：创建上下文并 resume。 */
          function unlock() {
            try {
              const ctx = ensureContext();
              if (!ctx) return false;
              if (typeof ctx.state === 'string' && ctx.state !== 'running') tryResume(ctx);
              return true;
            } catch (error) {
              return false;
            }
          }

          /** 排障快照（window.__dshSessionWatchdog.sound()）。 */
          function snapshot() {
            return {
              available: audioContextCtor() !== null,
              state: engine.ctx && typeof engine.ctx.state === 'string' ? engine.ctx.state : 'none',
              plays: engine.plays,
              lastSound: engine.lastSound,
              lastVolume: engine.lastVolume,
              lastError: engine.lastError,
              lastPlayedAt: engine.lastPlayedAt,
            };
          }

          /** 释放 AudioContext（卸载时调用；失败静默）。 */
          function dispose() {
            const ctx = engine.ctx;
            engine.ctx = null;
            if (!ctx || typeof ctx.close !== 'function') return;
            try {
              const result = ctx.close();
              if (result && typeof result.then === 'function') result.then(() => {}, () => {});
            } catch (error) {
              /* 忽略 */
            }
          }

          return { playSound: playSound, unlock: unlock, snapshot: snapshot, dispose: dispose };
        }

        // ────────────────────────────────────────────────────────────────────
        // 插件主体工厂：apply 时创建一份运行时（定时器 / DOM / 监听都在里面）
        // ────────────────────────────────────────────────────────────────────
        function createClientApply(require) {
          /** 当前实例的清理函数；非空说明已经跑起来了（防重复 apply）。 */
          let activeDispose = null;

          /**
           * Cordis 插件入口。
           * 要求：uiSession 缺失时不抛错（晚到的服务走 ctx.inject 兜底）。task-4 验收项
           */
          function apply(ctx) {
            try {
              if (!ctx || typeof ctx !== 'object') {
                warn('apply 收到的 ctx 非法，已跳过');
                return undefined;
              }
              if (activeDispose !== null) return activeDispose;
              let uiSessionReady = false;
              try {
                uiSessionReady = ctx.uiSession !== undefined && ctx.uiSession !== null;
              } catch (error) {
                // 未注入时直接读服务可能抛 Cordis 错误 —— 视为未就绪
                uiSessionReady = false;
              }
              if (uiSessionReady) {
                startRuntime(ctx);
                return activeDispose;
              }
              // 兜底：inject 只在宿主 honor 的情况下拦门；晚到的 provider 由 ctx.inject 接。
              // 出处：REFS/99galaxy-dsh-turn-notify-1.0.4/package/lib/client.js:843-853
              if (typeof ctx.inject === 'function') {
                try {
                  ctx.inject(['uiSession'], (scoped) => {
                    try {
                      const ready = readService(scoped, 'uiSession') !== null || (scoped && scoped.uiSession !== undefined);
                      if (!ready) return;
                      startRuntime(scoped);
                    } catch (error) {
                      warn('uiSession 晚到启动失败（已隔离）', error);
                    }
                  });
                } catch (error) {
                  warn('ctx.inject 调用失败（已隔离）', error);
                }
                return undefined;
              }
              warn('uiSession 不可用，浏览器半侧未启动（按契约不抛错，UI 保持原样）');
              return undefined;
            } catch (error) {
              warn('apply 执行失败（已隔离，不影响宿主页面）', error);
              return undefined;
            }
          }

          /** 创建运行时并注册 ctx.effect 清理。 */
          function startRuntime(ctx) {
            let app;
            try {
              app = createApp(ctx);
            } catch (error) {
              warn('创建运行时失败（已隔离）', error);
              return;
            }
            let disposed = false;
            const dispose = () => {
              if (disposed) return;
              disposed = true;
              activeDispose = null;
              try {
                app.dispose();
              } catch (error) {
                warn('运行时清理失败（已忽略）', error);
              }
            };
            activeDispose = dispose;
            try {
              app.start();
            } catch (error) {
              warn('运行时启动失败（已回滚）', error);
              dispose();
              return;
            }
            // 定时器 / 浮层 DOM / 事件监听 / 通知全部挂在 ctx.effect 上，插件重载时一次拆干净。
            // 出处：asar cordis/lib/index.js:463（ctx.effect 收集 disposer）
            try {
              if (typeof ctx.effect === 'function') {
                ctx.effect(
                  () => () => {
                    try {
                      dispose();
                    } catch (error) {
                      warn('effect 清理失败（已忽略）', error);
                    }
                  },
                  NS + ': client runtime',
                );
              } else {
                warn('ctx.effect 不可用：卸载时不会自动清理（不抛错）');
              }
            } catch (error) {
              warn('注册 ctx.effect 失败（已忽略）', error);
            }
          }

          /**
           * 一份运行时：拥有轮询状态、告警缓存、卡片 DOM、徽标状态与系统通知。
           * scope = 已经注入 uiSession 的 Cordis 上下文。
           */
          function createApp(scope) {
            const state = {
              started: false,
              stopped: false,
              /** 宿主 alerts 游标（since 参数） */
              cursor: 0,
              /** 连续失败次数，用于指数退避 */
              backoff: 0,
              pollTimer: undefined,
              config: Object.assign({}, DEFAULT_CONFIG),
              configLoaded: false,
              lastConfigAttemptAt: 0,
              notificationsDenied: false,
              /** alertId -> 最近一次 alert（宿主可能用同一 id 推进 stage） */
              alerts: new Map(),
              /** 已经弹过卡片/系统通知的 alertId（按 id 去重，同一事件只打扰一次） */
              toasted: new Set(),
              /** 正在显示中的卡片 [{ alert, el, timer, status }] */
              cards: [],
              /** 超出 4 张后排队等位的 alert */
              queue: [],
              /** 右上角浮层容器 */
              overlay: null,
              /** sessionId -> { level, label, at, alertId }（侧栏徽标数据源） */
              badgeStates: new Map(),
              badgeListeners: new Set(),
              badgeTimers: new Map(),
              /** 已播放过提示音的 alertId（同一条完成提醒只响一次） */
              sounded: new Set(),
              /** 已弹出的系统通知，卸载时统一 close */
              notifications: new Set(),
              /** 需要在 dispose 时调用的清理函数 */
              disposers: [],
              diagnostic: null,
            };

            /** 提示音引擎：由本运行时的设置面板「试听」与完成提醒共用。 */
            const soundEngine = createSoundEngine();

            // ────────────── 会话跳转 ──────────────

            /**
             * 打开指定会话。出处：02-ui-alert.md:957-975（ctx.uiWorkspace.openSession(sessionId)）
             * 服务可能还没提供，读不到时降级为只聚焦窗口。
             */
            function revealSession(sessionId) {
              try {
                const workspace = readService(scope, 'uiWorkspace');
                if (workspace && typeof workspace.openSession === 'function') {
                  workspace.openSession(sessionId);
                  return true;
                }
              } catch (error) {
                warn('打开会话失败（已隔离）', error);
              }
              try {
                if (typeof window.focus === 'function') window.focus();
              } catch (error) {
                /* 忽略 */
              }
              return false;
            }

            // ────────────── 配置 ──────────────

            /** 读取宿主配置；失败静默，保留默认值。 */
            async function loadConfig() {
              try {
                const response = await fetchWithTimeout(CONFIG_URL);
                if (!response || response.ok !== true) return;
                const payload = await response.json();
                if (!payload || typeof payload !== 'object' || payload.ok !== true) return;
                const remote = payload.config;
                if (!remote || typeof remote !== 'object') return;
                const next = Object.assign({}, DEFAULT_CONFIG);
                if (typeof remote.notifyOs === 'boolean') next.notifyOs = remote.notifyOs;
                if (typeof remote.notifyGui === 'boolean') next.notifyGui = remote.notifyGui;
                if (typeof remote.notifyOnCompletion === 'boolean') next.notifyOnCompletion = remote.notifyOnCompletion;
                if (typeof remote.completionSound === 'string' && COMPLETION_SOUNDS.indexOf(remote.completionSound) >= 0) {
                  next.completionSound = remote.completionSound;
                }
                const volume = Number(remote.completionVolume);
                if (Number.isFinite(volume)) next.completionVolume = Math.min(100, Math.max(0, Math.round(volume)));
                if (typeof remote.resumePromptMode === 'string' && RESUME_PROMPT_MODES.indexOf(remote.resumePromptMode) >= 0) {
                  next.resumePromptMode = remote.resumePromptMode;
                }
                const duration = Number(remote.toastDurationMs);
                if (Number.isFinite(duration)) next.toastDurationMs = Math.min(60000, Math.max(2000, Math.floor(duration)));
                state.config = next;
                state.configLoaded = true;
              } catch (error) {
                /* 配置拿不到就用默认值，下个重试周期再试 */
              }
            }

            // ────────────── 系统通知（Web Notification） ──────────────

            /**
             * 启动时申请一次通知权限。
             * 桌面端主窗口把非 media 权限一律放行（02-ui-alert.md:804-823），
             * 所以这里通常直接 granted；被拒则 state.notificationsDenied 永久降级为仅 toast。
             */
            function prepareNotifications() {
              try {
                if (typeof Notification === 'undefined') return;
                if (Notification.permission === 'denied') {
                  state.notificationsDenied = true;
                  return;
                }
                if (Notification.permission !== 'default') return;
                const request = Notification.requestPermission();
                if (request && typeof request.then === 'function') {
                  request
                    .then((permission) => {
                      if (permission === 'denied') state.notificationsDenied = true;
                    })
                    .catch(() => {
                      /* 老实现可能同步返回字符串，忽略 */
                    });
                }
              } catch (error) {
                /* 权限接口不可用：maybeNotifyOs 里按实时状态判断 */
              }
            }

            /**
             * 首次用户交互（pointerdown / keydown 之一）时解锁音频上下文：
             * 浏览器的自动播放策略要求先有用户手势，否则 AudioContext 一直是 suspended。
             * 只解锁一次，两个监听一起摘掉；任何环境问题都静默。
             */
            function installSoundUnlock() {
              try {
                if (typeof window === 'undefined' || typeof window.addEventListener !== 'function') return;
                let unlocked = false;
                const remove = () => {
                  try {
                    window.removeEventListener('pointerdown', handler);
                  } catch (error) {
                    /* 忽略 */
                  }
                  try {
                    window.removeEventListener('keydown', handler);
                  } catch (error) {
                    /* 忽略 */
                  }
                };
                const handler = () => {
                  if (unlocked) return;
                  unlocked = true;
                  remove();
                  try {
                    soundEngine.unlock();
                  } catch (error) {
                    /* 解锁失败：后续播放会静默返回 false */
                  }
                };
                window.addEventListener('pointerdown', handler);
                window.addEventListener('keydown', handler);
                state.disposers.push(remove);
              } catch (error) {
                /* 拿不到 window 事件：跳过解锁，播放时静默降级 */
              }
            }

            /**
             * 页面在后台时弹一条系统通知。出处：02-ui-alert.md:825-848（turn-notify 的生产写法：
             * 不传 silent、tag 只用安全字符）；点击 → openSession + window.focus()
             * 出处：02-ui-alert.md:979（notification.onclick 的推荐写法）
             */
            function maybeNotifyOs(alert) {
              try {
                if (state.stopped) return;
                if (!documentIsHidden()) return;
                if (state.config.notifyOs === false) return;
                if (typeof Notification === 'undefined') return;
                if (state.notificationsDenied) return;
                if (Notification.permission === 'denied') {
                  state.notificationsDenied = true;
                  return;
                }
                if (Notification.permission !== 'granted') return;
                const title = '会话哨兵 · ' + truncateText(resolveSessionTitle(alert.sessionId, alert.title), 60);
                const body = kindLabel(alert.kind) + '：' + describeAlert(alert);
                const notification = new Notification(title, {
                  body: body,
                  tag: 'dsh-session-watchdog-' + alert.id,
                });
                state.notifications.add(notification);
                const forget = () => {
                  try {
                    state.notifications.delete(notification);
                  } catch (error) {
                    /* 忽略 */
                  }
                };
                notification.onclose = forget;
                notification.onerror = forget;
                notification.onclick = () => {
                  forget();
                  try {
                    notification.close();
                  } catch (error) {
                    /* 忽略 */
                  }
                  revealSession(alert.sessionId);
                  try {
                    if (typeof window.focus === 'function') window.focus();
                  } catch (error) {
                    /* 忽略 */
                  }
                };
              } catch (error) {
                warn('系统通知失败（降级为页面内提醒）', error);
              }
            }

            // ────────────── 轮询 ──────────────

            /** 失败次数对应的等待时长（指数退避，封顶 30s）。 */
            function backoffDelay() {
              return Math.min(MAX_BACKOFF_MS, POLL_VISIBLE_MS * Math.pow(2, state.backoff));
            }

            /** 安排下一次轮询（会替换掉已有的定时器）。 */
            function scheduleTick(delay) {
              try {
                if (state.stopped) return;
                if (state.pollTimer !== undefined) clearTimeout(state.pollTimer);
                state.pollTimer = setTimeout(() => {
                  void tick();
                }, Math.max(0, delay));
              } catch (error) {
                /* 定时器不可用：放弃轮询，但已有 UI 不受影响 */
              }
            }

            /** 拉取一次 alerts；成功返回 payload，失败返回 null（异常在 tick 里统一处理）。 */
            async function fetchAlerts() {
              const url = ALERTS_URL + '?since=' + encodeURIComponent(String(state.cursor));
              const response = await fetchWithTimeout(url);
              if (!response || response.ok !== true) return null;
              const payload = await response.json();
              if (!payload || typeof payload !== 'object' || payload.ok !== true) return null;
              return payload;
            }

            /** 一次轮询：拉数据 → 分发 → 排下一次（异常绝不外抛）。 */
            async function tick() {
              state.pollTimer = undefined;
              if (state.stopped) return;
              try {
                if (!state.configLoaded && Date.now() - state.lastConfigAttemptAt > CONFIG_RETRY_MS) {
                  state.lastConfigAttemptAt = Date.now();
                  void loadConfig();
                }
              } catch (error) {
                /* 配置重试失败无所谓 */
              }
              let delay = documentIsHidden() ? POLL_HIDDEN_MS : POLL_VISIBLE_MS;
              try {
                const payload = await fetchAlerts();
                if (payload) {
                  state.backoff = 0;
                  applyAlerts(payload);
                } else {
                  state.backoff = Math.min(state.backoff + 1, MAX_BACKOFF_STEPS);
                  delay = backoffDelay();
                }
              } catch (error) {
                // 连接失败 / 404 / 超时：静默退避重试，不打扰用户
                state.backoff = Math.min(state.backoff + 1, MAX_BACKOFF_STEPS);
                delay = backoffDelay();
              }
              if (state.stopped) return;
              if (state.backoff === 0) delay = documentIsHidden() ? POLL_HIDDEN_MS : POLL_VISIBLE_MS;
              scheduleTick(delay);
            }

            // ────────────── alert 接收与分发 ──────────────

            /** 校验并规整宿主 alert；字段缺失/类型不对就丢弃（绝不因脏数据抛错）。 */
            function normalizeAlert(raw) {
              try {
                if (!raw || typeof raw !== 'object') return null;
                const id = typeof raw.id === 'string' ? raw.id : '';
                const sessionId = typeof raw.sessionId === 'string' ? raw.sessionId : '';
                if (id === '' || sessionId === '') return null;
                let at = Number(raw.at);
                if (!Number.isFinite(at) || at <= 0) at = Date.now();
                // 防御：宿主若误用秒级时间戳，这里统一成毫秒
                if (at < 1e12) at = at * 1000;
                return {
                  id: id,
                  sessionId: sessionId,
                  title: typeof raw.title === 'string' ? raw.title : '',
                  kind: typeof raw.kind === 'string' && raw.kind !== '' ? raw.kind : 'error',
                  stage: typeof raw.stage === 'string' && raw.stage !== '' ? raw.stage : 'detected',
                  reason: typeof raw.reason === 'string' ? raw.reason : '',
                  error: typeof raw.error === 'string' ? raw.error : null,
                  turn: typeof raw.turn === 'number' && Number.isFinite(raw.turn) ? raw.turn : null,
                  at: at,
                  resumeAt: typeof raw.resumeAt === 'number' && Number.isFinite(raw.resumeAt) ? raw.resumeAt : null,
                  resumeCount: typeof raw.resumeCount === 'number' && Number.isFinite(raw.resumeCount) ? raw.resumeCount : 0,
                  summary: typeof raw.summary === 'string' ? raw.summary : '',
                };
              } catch (error) {
                return null;
              }
            }

            /** 消费一次 alerts 响应：推进 cursor，逐条接受。 */
            function applyAlerts(payload) {
              try {
                const nextCursor = Number(payload.cursor);
                if (Number.isSafeInteger(nextCursor) && nextCursor > state.cursor) state.cursor = nextCursor;
                const list = Array.isArray(payload.alerts) ? payload.alerts : [];
                for (const raw of list) {
                  const alert = normalizeAlert(raw);
                  if (alert) acceptAlert(alert);
                }
              } catch (error) {
                warn('处理 alerts 响应失败（已隔离）', error);
              }
            }

            /**
             * 接受一条 alert：
             *   - 记入缓存并更新徽标（同一 id 的 stage 变化也要更新颜色）；
             *   - 同一 id 只弹一次卡片 + 系统通知（task-4 要求 2 的「按 id 去重」）。
             */
            function acceptAlert(alert) {
              try {
                state.alerts.set(alert.id, alert);
                pruneCollections();
                // 徽标永远跟随最新 stage（任务完成 = 绿色完成态，沿用绿色 30s 自清逻辑）
                setBadge(alert.sessionId, {
                  level: levelOf(alert),
                  label: badgeLabelOf(alert),
                  at: alert.at,
                  alertId: alert.id,
                });
                // 同一条 alert 的 stage 变化：同步正在显示的卡片（不新增卡片）
                refreshCardAlert(findCard(alert.id), alert);
                // 同一 id 只打扰一次：后续 stage 推进只更新徽标/卡片，不再弹卡片或系统通知。
                // （宿主按 since=cursor 增量下发，刷新页面时若仍有未处理告警会重新提醒一次，这是期望行为）
                const firstTime = !state.toasted.has(alert.id);
                if (!firstTime) return;
                rememberToasted(alert.id);
                if (state.config.notifyGui !== false) enqueueCard(alert);
                maybeNotifyOs(alert);
                maybePlayCompletionSound(alert);
              } catch (error) {
                warn('接受 alert 失败（已隔离）', error);
              }
            }

            /**
             * 任务完成提醒：按配置播一次提示音。
             * 条件：kind === 'completed' && notifyOnCompletion !== false && completionSound !== 'none'；
             * 同一条 alert 只响一次（state.sounded 兜底，stage 推进不会重播）。任何异常都静默。
             */
            function maybePlayCompletionSound(alert) {
              try {
                if (!alert || alert.kind !== 'completed') return false;
                if (state.config.notifyOnCompletion === false) return false;
                if (state.sounded.has(alert.id)) return false;
                const soundId = typeof state.config.completionSound === 'string'
                  ? state.config.completionSound
                  : DEFAULT_CONFIG.completionSound;
                if (soundId === 'none') return false;
                // 先登记再播放：即使播放失败也不重复尝试，避免同一提醒反复出声
                state.sounded.add(alert.id);
                return soundEngine.playSound(soundId, state.config.completionVolume);
              } catch (error) {
                return false;
              }
            }

            function rememberToasted(alertId) {
              try {
                state.toasted.add(alertId);
              } catch (error) {
                /* 忽略 */
              }
            }

            /** 缓存上限：长期开着页面也不无限增长。 */
            function pruneCollections() {
              try {
                if (state.alerts.size > 300) {
                  const keys = Array.from(state.alerts.keys());
                  for (let index = 0; index < keys.length - 200; index += 1) state.alerts.delete(keys[index]);
                }
                if (state.toasted.size > 500) {
                  const keys = Array.from(state.toasted.values());
                  for (let index = 0; index < keys.length - 300; index += 1) state.toasted.delete(keys[index]);
                }
                if (state.sounded.size > 500) {
                  const keys = Array.from(state.sounded.values());
                  for (let index = 0; index < keys.length - 300; index += 1) state.sounded.delete(keys[index]);
                }
              } catch (error) {
                /* 忽略 */
              }
            }

            // ────────────── 侧栏徽标 ──────────────

            function notifyBadge() {
              for (const listener of Array.from(state.badgeListeners)) {
                try {
                  listener();
                } catch (error) {
                  /* 单个订阅者出错不影响其他人 */
                }
              }
            }

            /** 写入/更新某会话的徽标状态。 */
            function setBadge(sessionId, info) {
              if (state.stopped || typeof sessionId !== 'string' || sessionId === '') return;
              try {
                state.badgeStates.set(sessionId, info);
                notifyBadge();
                const timers = state.badgeTimers;
                const existing = timers.get(sessionId);
                if (existing !== undefined) {
                  try {
                    clearTimeout(existing);
                  } catch (error) {
                    /* 忽略 */
                  }
                  timers.delete(sessionId);
                }
                // 绿点属于「已经好了」的信息，保留一会儿后自动清掉，避免一直挂着
                if (info.level === 'resumed') {
                  const timer = setTimeout(() => {
                    try {
                      const current = state.badgeStates.get(sessionId);
                      if (current && current.alertId === info.alertId && current.level === 'resumed') {
                        state.badgeStates.delete(sessionId);
                        notifyBadge();
                      }
                    } catch (error) {
                      /* 忽略 */
                    }
                    state.badgeTimers.delete(sessionId);
                  }, BADGE_RESUMED_TTL_MS);
                  timers.set(sessionId, timer);
                }
              } catch (error) {
                /* 徽标失败不影响主流程 */
              }
            }

            /** 移除徽标；给了 alertId 时只在它仍是当前事件时才移除。 */
            function clearBadge(sessionId, alertId) {
              try {
                const current = state.badgeStates.get(sessionId);
                if (!current) return;
                if (alertId !== undefined && current.alertId !== alertId) return;
                state.badgeStates.delete(sessionId);
                const timer = state.badgeTimers.get(sessionId);
                if (timer !== undefined) {
                  try {
                    clearTimeout(timer);
                  } catch (error) {
                    /* 忽略 */
                  }
                  state.badgeTimers.delete(sessionId);
                }
                notifyBadge();
              } catch (error) {
                /* 忽略 */
              }
            }

            /**
             * 注册侧栏行尾徽标组件。
             * 槽是 list + inline，条目必须给 id（02-ui-alert.md:423）；
             * 一律用 slots.inject 等槽声明后再注册，直接 register 会抛错（02-ui-alert.md:430）。
             */
            function installBadgeSlot() {
              let installed = false;
              const attempt = (ctxLike) => {
                if (state.stopped || installed) return;
                const slots = readService(ctxLike, 'slots');
                if (!slots || typeof slots.inject !== 'function' || typeof slots.register !== 'function') return;
                let React = null;
                try {
                  React = require('react');
                } catch (error) {
                  React = null;
                }
                if (!React || typeof React.createElement !== 'function' || typeof React.useState !== 'function') {
                  warn('react 不可用，侧栏徽标跳过（提醒卡片不受影响）');
                  return;
                }
                installed = true;
                const Badge = createBadgeComponent(React);
                try {
                  const dispose = slots.inject(BADGE_SLOT, () =>
                    slots.register(
                      {
                        name: BADGE_SLOT,
                        id: 'dsh-session-watchdog-badge',
                        order: 10,
                      },
                      Badge,
                    ),
                  );
                  if (typeof dispose === 'function') state.disposers.push(dispose);
                } catch (error) {
                  warn('注册 ' + BADGE_SLOT + ' 失败（已跳过徽标，仅保留提醒卡片）', error);
                }
              };
              attempt(scope);
              if (installed || state.stopped) return;
              // slots 服务晚到时的兜底（同样不抛错）
              try {
                if (typeof scope.inject === 'function') scope.inject(['slots'], (scoped) => attempt(scoped));
              } catch (error) {
                /* v1 允许只有提醒卡片：task-4 要求 4 */
              }
            }

            /**
             * 徽标组件：props 只有 sessionId（02-ui-alert.md:265 官方 README 原文）。
             * 会话没有事件时返回 null = 零渲染。
             */
            function createBadgeComponent(React) {
              return function SessionWatchdogBadge(props) {
                let sessionId = '';
                try {
                  sessionId = props && typeof props.sessionId === 'string' ? props.sessionId : '';
                } catch (error) {
                  sessionId = '';
                }
                const setRevision = React.useState(0)[1];
                React.useEffect(() => {
                  if (sessionId === '' || state.stopped) return undefined;
                  const listener = () => {
                    try {
                      setRevision((value) => value + 1);
                    } catch (error) {
                      /* 忽略 */
                    }
                  };
                  state.badgeListeners.add(listener);
                  return () => {
                    try {
                      state.badgeListeners.delete(listener);
                    } catch (error) {
                      /* 忽略 */
                    }
                  };
                }, [sessionId]);
                const info = sessionId === '' ? undefined : state.badgeStates.get(sessionId);
                if (!info) return null;
                const color = LEVEL_COLOR[info.level] || LEVEL_COLOR.error;
                return React.createElement(
                  'span',
                  {
                    'data-dsh-watchdog-badge': info.level,
                    role: 'button',
                    tabIndex: 0,
                    title: info.label + '（点击打开会话）',
                    'aria-label': info.label,
                    onClick: (event) => {
                      try {
                        event.preventDefault();
                        event.stopPropagation();
                      } catch (error) {
                        /* 忽略 */
                      }
                      revealSession(sessionId);
                    },
                    style: {
                      display: 'inline-flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      width: '14px',
                      height: '14px',
                      marginLeft: '4px',
                      flex: 'none',
                      cursor: 'pointer',
                      verticalAlign: 'middle',
                    },
                  },
                  React.createElement('span', {
                    style: {
                      display: 'block',
                      width: '7px',
                      height: '7px',
                      borderRadius: '50%',
                      background: color,
                      boxShadow: '0 0 0 2px rgba(0,0,0,.18)',
                    },
                  }),
                );
              };
            }

            // ────────────── 设置页（官方槽 settings.section） ──────────────

            /**
             * 读写宿主完整配置。契约（Lead 已实测，不要改宿主）：
             *   GET  /dsh-session-watchdog/config →
             *        { ok:true, version, editable:string[], config:{...}, defaults:{...}, updatedAt }
             *   POST /dsh-session-watchdog/config body 二选一：{ patch:{字段:值} } 或 { reset:true }
             *        成功 200 返回同一份全量；失败 400 { ok:false, error }
             * 宿主实现：lib/notify.js:166-192；client fetch 范式：02-ui-alert.md:924-948、:560
             */
            async function requestConfigPayload(method, body) {
              const action = method === 'POST' ? '保存' : '读取';
              const init = { method: method, cache: 'no-store', headers: { accept: 'application/json' } };
              if (body !== undefined && body !== null) {
                init.headers['content-type'] = 'application/json';
                init.body = JSON.stringify(body);
              }
              let response = null;
              try {
                response = await fetchWithTimeout(CONFIG_URL, init);
              } catch (error) {
                throw new Error(action + '失败：网络请求异常（' + errorMessage(error) + '）');
              }
              if (!response || typeof response !== 'object') throw new Error('当前环境不支持 fetch，无法' + action + '设置');
              let payload = null;
              let parseFailed = false;
              try {
                payload = await response.json();
              } catch (error) {
                parseFailed = true;
              }
              if (response.ok !== true) {
                const detail = payload && typeof payload.error === 'string' && payload.error !== ''
                  ? payload.error
                  : typeof response.status === 'number'
                    ? 'HTTP ' + response.status
                    : '宿主返回错误';
                throw new Error(action + '失败：' + detail);
              }
              if (!payload || typeof payload !== 'object') {
                throw new Error(action + '失败：' + (parseFailed ? '响应不是合法 JSON' : '响应格式异常'));
              }
              if (payload.ok !== true) {
                throw new Error(action + '失败：' + (payload.error ? String(payload.error) : '宿主拒绝该操作'));
              }
              return payload;
            }

            /**
             * 注册「设置 → 会话哨兵」整页。
             * 注册模式照抄 installBadgeSlot（同文件 :804-846）：槽未声明时直接 register 会抛错，
             * 必须先 slots.inject 等槽声明（02-ui-alert.md:430）。
             * 槽定义：02-ui-alert.md:892（settings.section 是 list 槽，条目需 id + order + label）。
             * 任何一步失败（无 slots / 无 React / 注册抛错）都静默跳过，绝不影响提醒卡片与徽标。
             */
            function installSettingsSlot() {
              let installed = false;
              const attempt = (ctxLike) => {
                try {
                  if (state.stopped || installed) return;
                  const slots = readService(ctxLike, 'slots');
                  if (!slots || typeof slots.inject !== 'function' || typeof slots.register !== 'function') return;
                  let React = null;
                  try {
                    React = require('react');
                  } catch (error) {
                    React = null;
                  }
                  if (!React || typeof React.createElement !== 'function' || typeof React.useState !== 'function' || typeof React.useEffect !== 'function') {
                    warn('react 不可用，设置面板跳过（提醒卡片与徽标不受影响）');
                    return;
                  }
                  installed = true;
                  const Panel = createSettingsComponent(React, soundEngine);
                  try {
                    const dispose = slots.inject(SETTINGS_SLOT, () =>
                      slots.register(
                        {
                          name: SETTINGS_SLOT,
                          id: SETTINGS_ENTRY_ID,
                          order: SETTINGS_ORDER,
                          label: () => '会话哨兵',
                        },
                        Panel,
                      ),
                    );
                    if (typeof dispose === 'function') state.disposers.push(dispose);
                  } catch (error) {
                    warn('注册 ' + SETTINGS_SLOT + ' 失败（已跳过设置面板，其余功能不受影响）', error);
                  }
                } catch (error) {
                  warn('安装设置页失败（已忽略）', error);
                }
              };
              attempt(scope);
              if (installed || state.stopped) return;
              // slots 服务晚到时的兜底（与安装徽标同一套写法，失败静默）
              try {
                if (typeof scope.inject === 'function') scope.inject(['slots'], (scoped) => attempt(scoped));
              } catch (error) {
                /* 拿不到 slots：按契约保持宿主页面原样 */
              }
            }

            /**
             * 设置面板组件。
             * 只依赖 React（useState / useEffect / useCallback，useRef 可选）；不引外部依赖、不注入全局 CSS。
             * 卸载后不再 setState：所有异步回调先检查 mountedRef。
             */
            function createSettingsComponent(React, sound) {
              const h = React.createElement;
              // useRef 缺失时退化为 useState 常量对象（同样是稳定引用，且 hook 顺序不变）
              const useMountedRef = typeof React.useRef === 'function'
                ? function useRefMounted() {
                    return React.useRef(true);
                  }
                : function useStateMounted() {
                    return React.useState(function () {
                      return { current: true };
                    })[0];
                  };
              const useCallback = typeof React.useCallback === 'function'
                ? function useMemoizedCallback(fn, deps) {
                    return React.useCallback(fn, deps);
                  }
                : function usePlainCallback(fn) {
                    return fn;
                  };

              /** 全部样式内联，跟着配色走；紧凑、不遮挡。 */
              function makeStyles(palette) {
                const rowBase = {
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: '12px',
                  padding: '7px 0',
                };
                const buttonBase = {
                  appearance: 'none',
                  WebkitAppearance: 'none',
                  fontFamily: 'inherit',
                  lineHeight: '18px',
                  borderRadius: '6px',
                  cursor: 'pointer',
                };
                return {
                  root: {
                    maxWidth: '780px',
                    padding: '4px 2px',
                    color: palette.text,
                    fontFamily: 'inherit',
                    fontSize: '13px',
                    lineHeight: '1.55',
                  },
                  heading: { margin: '0 0 3px', fontSize: '15px', fontWeight: '600', color: palette.text },
                  subtitle: { margin: 0, fontSize: '12px', color: palette.muted },
                  card: {
                    marginBottom: '10px',
                    padding: '10px 14px',
                    border: '1px solid ' + palette.border,
                    borderRadius: '10px',
                    background: palette.bg,
                  },
                  cardTitle: { margin: '0 0 2px', fontSize: '13px', fontWeight: '600', color: palette.text },
                  cardHint: { margin: '0 0 2px', fontSize: '12px', color: palette.muted },
                  row: Object.assign({}, rowBase, { borderTop: '1px solid ' + palette.divider }),
                  rowFirst: rowBase,
                  rowText: { flex: '1 1 auto', minWidth: 0 },
                  label: { fontSize: '13px', color: palette.text },
                  hint: { marginTop: '1px', fontSize: '11.5px', color: palette.muted },
                  checkbox: {
                    width: '16px',
                    height: '16px',
                    margin: 0,
                    accentColor: palette.primary,
                    cursor: 'pointer',
                    flex: 'none',
                  },
                  numberInput: {
                    width: '96px',
                    flex: 'none',
                    boxSizing: 'border-box',
                    padding: '4px 8px',
                    fontFamily: 'inherit',
                    fontSize: '12.5px',
                    color: palette.text,
                    background: palette.inputBg,
                    border: '1px solid ' + palette.inputBorder,
                    borderRadius: '6px',
                    outline: 'none',
                  },
                  selectRow: { display: 'flex', alignItems: 'center', gap: '6px', flex: 'none' },
                  select: {
                    flex: 'none',
                    minWidth: '168px',
                    boxSizing: 'border-box',
                    padding: '4px 8px',
                    fontFamily: 'inherit',
                    fontSize: '12.5px',
                    color: palette.text,
                    background: palette.inputBg,
                    border: '1px solid ' + palette.inputBorder,
                    borderRadius: '6px',
                    outline: 'none',
                    cursor: 'pointer',
                  },
                  textInput: {
                    flex: '1 1 auto',
                    minWidth: 0,
                    boxSizing: 'border-box',
                    padding: '5px 8px',
                    fontFamily: 'inherit',
                    fontSize: '12.5px',
                    color: palette.text,
                    background: palette.inputBg,
                    border: '1px solid ' + palette.inputBorder,
                    borderRadius: '6px',
                    outline: 'none',
                  },
                  smallButton: Object.assign({}, buttonBase, {
                    flex: 'none',
                    padding: '4px 10px',
                    fontSize: '12px',
                    color: palette.text,
                    background: 'transparent',
                    border: '1px solid ' + palette.inputBorder,
                  }),
                  primaryButton: Object.assign({}, buttonBase, {
                    padding: '5px 14px',
                    fontSize: '12.5px',
                    fontWeight: '600',
                    color: palette.primaryText,
                    background: palette.primary,
                    border: '1px solid ' + palette.primary,
                  }),
                  ghostButton: Object.assign({}, buttonBase, {
                    padding: '5px 14px',
                    fontSize: '12.5px',
                    color: palette.muted,
                    background: 'transparent',
                    border: '1px solid ' + palette.inputBorder,
                  }),
                  dangerButton: Object.assign({}, buttonBase, {
                    padding: '5px 14px',
                    fontSize: '12.5px',
                    color: palette.danger,
                    background: 'transparent',
                    border: '1px solid ' + palette.danger,
                  }),
                  disabledButton: { opacity: 0.55, cursor: 'default' },
                  column: { padding: '8px 0', borderTop: '1px solid ' + palette.divider },
                  columnFirst: { padding: '8px 0' },
                  chipRow: { display: 'flex', flexWrap: 'wrap', gap: '6px', marginTop: '6px' },
                  chip: {
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '2px',
                    maxWidth: '100%',
                    padding: '1px 4px 1px 8px',
                    fontSize: '11.5px',
                    color: palette.chipText,
                    background: palette.chipBg,
                    border: '1px solid ' + palette.chipBorder,
                    borderRadius: '999px',
                  },
                  chipText: { overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
                  chipDelete: {
                    appearance: 'none',
                    WebkitAppearance: 'none',
                    padding: '0 3px',
                    fontFamily: 'inherit',
                    fontSize: '12px',
                    lineHeight: '16px',
                    color: palette.chipText,
                    background: 'transparent',
                    border: 'none',
                    cursor: 'pointer',
                  },
                  kindsRow: { display: 'flex', flexWrap: 'wrap', gap: '6px 18px', marginTop: '6px' },
                  kindItem: {
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: '6px',
                    fontSize: '12.5px',
                    color: palette.text,
                  },
                  footer: { display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: '8px', marginTop: '10px' },
                  meta: { marginTop: '6px', fontSize: '11.5px', color: palette.muted },
                };
              }

              return function SessionWatchdogSettingsPanel() {
                const [dark, setDark] = React.useState(readPrefersDark);
                const [status, setStatus] = React.useState('loading');
                const [errorText, setErrorText] = React.useState('');
                const [meta, setMeta] = React.useState({ editable: [], defaults: {}, updatedAt: 0 });
                const [form, setForm] = React.useState(null);
                const [initial, setInitial] = React.useState(null);
                const [drafts, setDrafts] = React.useState({});
                const [saving, setSaving] = React.useState(false);
                const [notice, setNotice] = React.useState({ kind: '', text: '' });
                const [confirmReset, setConfirmReset] = React.useState(false);
                const mountedRef = useMountedRef();

                /** 用宿主响应刷新表单与基线（保存成功后也调用它）。 */
                const applyPayload = useCallback(function applyPayload(payload) {
                  const config = payload && payload.config && typeof payload.config === 'object' ? payload.config : {};
                  const defaults = payload && payload.defaults && typeof payload.defaults === 'object' ? payload.defaults : {};
                  const editable = payload && Array.isArray(payload.editable)
                    ? payload.editable.filter(function (item) {
                        return typeof item === 'string';
                      })
                    : [];
                  setMeta({
                    editable: editable,
                    defaults: panelFromConfig(defaults),
                    updatedAt: Number(payload && payload.updatedAt) || 0,
                  });
                  setForm(panelFromConfig(config));
                  setInitial(panelFromConfig(config));
                  setStatus('ready');
                  setErrorText('');
                }, []);

                /** 进入面板 / 点重试时读一次配置。 */
                const load = useCallback(function load() {
                  setErrorText('');
                  setStatus(function (prev) {
                    return prev === 'ready' ? prev : 'loading';
                  });
                  requestConfigPayload('GET').then(
                    function (payload) {
                      if (mountedRef.current !== true) return;
                      applyPayload(payload);
                    },
                    function (error) {
                      if (mountedRef.current !== true) return;
                      setStatus(function (prev) {
                        return prev === 'ready' ? prev : 'error';
                      });
                      setErrorText(errorMessage(error));
                      setNotice({ kind: 'error', text: '读取配置失败：' + errorMessage(error) });
                    },
                  );
                }, [applyPayload, mountedRef]);

                // 挂载：读配置；卸载：清标记，之后所有异步回调都不再 setState
                React.useEffect(function onMount() {
                  mountedRef.current = true;
                  load();
                  return function onUnmount() {
                    mountedRef.current = false;
                  };
                }, [load, mountedRef]);

                // 暗色跟随系统（不支持 matchMedia 时保持浅色）
                React.useEffect(function watchColorScheme() {
                  try {
                    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return undefined;
                    const query = window.matchMedia('(prefers-color-scheme: dark)');
                    if (!query) return undefined;
                    const handler = function () {
                      try {
                        if (mountedRef.current === true) setDark(query.matches === true);
                      } catch (error) {
                        /* 忽略 */
                      }
                    };
                    if (typeof query.addEventListener === 'function') {
                      query.addEventListener('change', handler);
                      return function cleanup() {
                        try {
                          query.removeEventListener('change', handler);
                        } catch (error) {
                          /* 忽略 */
                        }
                      };
                    }
                    if (typeof query.addListener === 'function') {
                      query.addListener(handler);
                      return function cleanup() {
                        try {
                          query.removeListener(handler);
                        } catch (error) {
                          /* 忽略 */
                        }
                      };
                    }
                    return undefined;
                  } catch (error) {
                    return undefined;
                  }
                }, [mountedRef]);

                // 「恢复默认」的二次确认 5 秒后自动取消，避免误触后一直停在确认态
                React.useEffect(function watchResetConfirm() {
                  if (confirmReset !== true) return undefined;
                  let timer;
                  try {
                    timer = setTimeout(function () {
                      if (mountedRef.current === true) setConfirmReset(false);
                    }, 5000);
                  } catch (error) {
                    timer = undefined;
                  }
                  return function cleanup() {
                    try {
                      if (timer !== undefined) clearTimeout(timer);
                    } catch (error) {
                      /* 忽略 */
                    }
                  };
                }, [confirmReset, mountedRef]);

                function applyChange(key, value) {
                  setForm(function (prev) {
                    if (!prev) return prev;
                    const next = Object.assign({}, prev);
                    next[key] = value;
                    return next;
                  });
                  setConfirmReset(false);
                }

                function setDraftValue(key, value) {
                  setDrafts(function (prev) {
                    const next = Object.assign({}, prev);
                    next[key] = value;
                    return next;
                  });
                }

                function onToggle(field, event) {
                  try {
                    const checked = event && event.target && typeof event.target.checked === 'boolean'
                      ? event.target.checked
                      : !(form && form[field.key] === true);
                    applyChange(field.key, checked);
                  } catch (error) {
                    warn('设置开关切换失败（已忽略）', error);
                  }
                }

                function onNumberChange(field, event) {
                  try {
                    const value = event && event.target && typeof event.target.value === 'string' ? event.target.value : '';
                    applyChange(field.key, value);
                  } catch (error) {
                    warn('设置数值输入失败（已忽略）', error);
                  }
                }

                /** 下拉切换：只接受候选值（脏值回落字段默认项）。 */
                function onSelectChange(field, event) {
                  try {
                    const value = event && event.target && typeof event.target.value === 'string' ? event.target.value : '';
                    applyChange(field.key, normalizeSelectValue(field, value));
                  } catch (error) {
                    warn('设置下拉切换失败（已忽略）', error);
                  }
                }

                /** 试听用的音量：取当前表单文本，空/非法回落默认值，再钳到字段范围。 */
                function previewVolumeOf() {
                  const field = FIELD_BY_KEY.completionVolume;
                  const text = form && typeof form.completionVolume === 'string' ? form.completionVolume.trim() : '';
                  if (text === '') return DEFAULT_CONFIG.completionVolume;
                  const num = Number(text);
                  if (!Number.isFinite(num)) return DEFAULT_CONFIG.completionVolume;
                  return clampFieldNumber(field, num);
                }

                /** 「试听」：用当前选中音色 + 当前表单音量真实播一次；失败静默，不弹错误、不影响保存。 */
                function onPreviewSound(field) {
                  try {
                    const soundId = normalizeSelectValue(field, form && form.completionSound);
                    if (soundId === 'none') return;
                    if (!sound || typeof sound.playSound !== 'function') return;
                    sound.playSound(soundId, previewVolumeOf());
                  } catch (error) {
                    /* 试听失败静默：提示音不是核心功能 */
                  }
                }

                function onKindToggle(field, kind, event) {
                  try {
                    const checked = Boolean(event && event.target && event.target.checked === true);
                    const current = form && Array.isArray(form[field.key]) ? form[field.key] : [];
                    const next = RESUME_KINDS.filter(function (item) {
                      if (item === kind) return checked;
                      return current.indexOf(item) >= 0;
                    });
                    applyChange(field.key, next);
                  } catch (error) {
                    warn('设置多选切换失败（已忽略）', error);
                  }
                }

                function onListInput(field, event) {
                  try {
                    const value = event && event.target && typeof event.target.value === 'string' ? event.target.value : '';
                    setDraftValue(field.key, value);
                  } catch (error) {
                    warn('设置输入框更新失败（已忽略）', error);
                  }
                }

                function onListAdd(field) {
                  try {
                    const draft = drafts[field.key];
                    const text = String(draft === undefined || draft === null ? '' : draft).trim();
                    if (text === '') return;
                    const current = form && Array.isArray(form[field.key]) ? form[field.key] : [];
                    if (current.indexOf(text) < 0) applyChange(field.key, current.concat([text]));
                    setDraftValue(field.key, '');
                  } catch (error) {
                    warn('添加监控范围条目失败（已忽略）', error);
                  }
                }

                function onListKeyDown(field, event) {
                  try {
                    if (event && event.key === 'Enter') {
                      event.preventDefault();
                      onListAdd(field);
                    }
                  } catch (error) {
                    /* 忽略 */
                  }
                }

                function onListRemove(field, index) {
                  try {
                    const current = form && Array.isArray(form[field.key]) ? form[field.key] : [];
                    applyChange(
                      field.key,
                      current.filter(function (item, itemIndex) {
                        return itemIndex !== index;
                      }),
                    );
                  } catch (error) {
                    warn('删除监控范围条目失败（已忽略）', error);
                  }
                }

                function notifyFromError(prefix, error) {
                  try {
                    setNotice({ kind: 'error', text: prefix + '：' + errorMessage(error) });
                  } catch (nested) {
                    /* 忽略 */
                  }
                }

                /** 提交写请求（patch 或 reset），成功后用响应刷新表单。 */
                async function submitSettings(body, okText) {
                  try {
                    setSaving(true);
                    setNotice({ kind: '', text: '' });
                    const payload = await requestConfigPayload('POST', body);
                    if (mountedRef.current !== true) return;
                    applyPayload(payload);
                    setConfirmReset(false);
                    setNotice({ kind: 'ok', text: okText });
                  } catch (error) {
                    if (mountedRef.current !== true) return;
                    setNotice({ kind: 'error', text: errorMessage(error) });
                  } finally {
                    if (mountedRef.current === true) setSaving(false);
                  }
                }

                function onSubmitSave() {
                  try {
                    if (saving || !form || !initial) return;
                    const info = buildSettingsPatch(form, initial, meta.editable);
                    if (info.invalidLabels.length > 0) {
                      setNotice({
                        kind: 'error',
                        text: '下面这几项需要填写不小于 0 的数字：' + info.invalidLabels.join('、'),
                      });
                      return;
                    }
                    if (Object.keys(info.patch).length === 0) {
                      setNotice({ kind: 'info', text: '没有需要保存的改动' });
                      return;
                    }
                    void submitSettings({ patch: info.patch }, '已保存并即时生效');
                  } catch (error) {
                    notifyFromError('保存失败', error);
                  }
                }

                function onResetClick() {
                  try {
                    if (saving) return;
                    if (confirmReset !== true) {
                      setNotice({ kind: '', text: '' });
                      setConfirmReset(true);
                      return;
                    }
                    void submitSettings({ reset: true }, '已恢复默认并即时生效');
                  } catch (error) {
                    notifyFromError('恢复默认失败', error);
                  }
                }

                function onRetry() {
                  try {
                    void load();
                  } catch (error) {
                    notifyFromError('重试失败', error);
                  }
                }

                const palette = dark === true ? SETTINGS_PALETTE_DARK : SETTINGS_PALETTE_LIGHT;
                const styles = makeStyles(palette);
                const busy = saving === true;
                const editableNow = meta.editable;
                const defaultPanel = meta.defaults && typeof meta.defaults === 'object' ? meta.defaults : {};
                const dirty = form && initial
                  ? buildSettingsPatch(form, initial, editableNow)
                  : { patch: {}, invalidLabels: [], count: 0 };

                function renderBoolRow(field, first) {
                  const checked = form && form[field.key] === true;
                  const isDisabled = busy || !isFieldEditable(editableNow, field.key);
                  return h(
                    'div',
                    { key: field.key, style: first ? styles.rowFirst : styles.row },
                    h(
                      'div',
                      { style: styles.rowText },
                      h('div', { style: styles.label }, field.label),
                      field.hint ? h('div', { style: styles.hint }, field.hint) : null,
                    ),
                    h('input', {
                      'data-dsh-watchdog-field': field.key,
                      type: 'checkbox',
                      checked: Boolean(checked),
                      disabled: isDisabled,
                      style: styles.checkbox,
                      onChange: function (event) {
                        onToggle(field, event);
                      },
                    }),
                  );
                }

                function renderNumberRow(field, first) {
                  const value = form && typeof form[field.key] === 'string' ? form[field.key] : '';
                  const placeholder = typeof defaultPanel[field.key] === 'string' ? defaultPanel[field.key] : '';
                  const isDisabled = busy || !isFieldEditable(editableNow, field.key);
                  return h(
                    'div',
                    { key: field.key, style: first ? styles.rowFirst : styles.row },
                    h(
                      'div',
                      { style: styles.rowText },
                      h('div', { style: styles.label }, field.label),
                      field.hint ? h('div', { style: styles.hint }, field.hint) : null,
                    ),
                    h('input', {
                      'data-dsh-watchdog-field': field.key,
                      type: 'number',
                      inputMode: 'decimal',
                      min: '0',
                      step: '1',
                      value: value,
                      placeholder: placeholder,
                      disabled: isDisabled,
                      style: styles.numberInput,
                      onChange: function (event) {
                        onNumberChange(field, event);
                      },
                    }),
                  );
                }

                function renderSelectRow(field, first) {
                  const value = form ? normalizeSelectValue(field, form[field.key]) : '';
                  const isDisabled = busy || !isFieldEditable(editableNow, field.key);
                  const options = Array.isArray(field.options) ? field.options : [];
                  return h(
                    'div',
                    { key: field.key, style: first ? styles.rowFirst : styles.row },
                    h(
                      'div',
                      { style: styles.rowText },
                      h('div', { style: styles.label }, field.label),
                      field.hint ? h('div', { style: styles.hint }, field.hint) : null,
                    ),
                    h(
                      'div',
                      { style: styles.selectRow },
                      h(
                        'select',
                        {
                          'data-dsh-watchdog-field': field.key,
                          value: value,
                          disabled: isDisabled,
                          style: styles.select,
                          onChange: function (event) {
                            onSelectChange(field, event);
                          },
                        },
                        options.map(function (option) {
                          return h('option', { key: option.value, value: option.value }, option.label);
                        }),
                      ),
                      field.preview === true
                        ? h(
                            'button',
                            {
                              'data-dsh-watchdog-preview': field.key,
                              type: 'button',
                              disabled: busy,
                              title: '试听当前提示音',
                              'aria-label': '试听当前提示音',
                              style: busy
                                ? Object.assign({}, styles.smallButton, styles.disabledButton)
                                : styles.smallButton,
                              onClick: function () {
                                onPreviewSound(field);
                              },
                            },
                            '试听',
                          )
                        : null,
                    ),
                  );
                }

                function renderKindField(field, first) {
                  const selected = form && Array.isArray(form[field.key]) ? form[field.key] : [];
                  const isDisabled = busy || !isFieldEditable(editableNow, field.key);
                  return h(
                    'div',
                    { key: field.key, style: first ? styles.columnFirst : styles.column },
                    h('div', { style: styles.label }, field.label),
                    field.hint ? h('div', { style: styles.hint }, field.hint) : null,
                    h(
                      'div',
                      { style: styles.kindsRow },
                      RESUME_KINDS.map(function (kind) {
                        return h(
                          'label',
                          { key: kind, style: styles.kindItem },
                          h('input', {
                            'data-dsh-watchdog-kind': kind,
                            type: 'checkbox',
                            checked: selected.indexOf(kind) >= 0,
                            disabled: isDisabled,
                            style: styles.checkbox,
                            onChange: function (event) {
                              onKindToggle(field, kind, event);
                            },
                          }),
                          h('span', null, kindLabel(kind)),
                        );
                      }),
                    ),
                  );
                }

                function renderListField(field, first) {
                  const items = form && Array.isArray(form[field.key]) ? form[field.key] : [];
                  const draft = drafts[field.key];
                  const draftText = draft === undefined || draft === null ? '' : String(draft);
                  const isDisabled = busy || !isFieldEditable(editableNow, field.key);
                  return h(
                    'div',
                    { key: field.key, style: first ? styles.columnFirst : styles.column },
                    h('div', { style: styles.label }, field.label),
                    field.hint ? h('div', { style: styles.hint }, field.hint) : null,
                    h(
                      'div',
                      { style: { display: 'flex', alignItems: 'center', gap: '6px', marginTop: '5px' } },
                      h('input', {
                        'data-dsh-watchdog-input': field.key,
                        type: 'text',
                        value: draftText,
                        placeholder: field.placeholder || '输入后点「添加」',
                        disabled: isDisabled,
                        style: styles.textInput,
                        onChange: function (event) {
                          onListInput(field, event);
                        },
                        onKeyDown: function (event) {
                          onListKeyDown(field, event);
                        },
                      }),
                      h(
                        'button',
                        {
                          'data-dsh-watchdog-add': field.key,
                          type: 'button',
                          disabled: isDisabled,
                          style: isDisabled ? Object.assign({}, styles.smallButton, styles.disabledButton) : styles.smallButton,
                          onClick: function () {
                            onListAdd(field);
                          },
                        },
                        '添加',
                      ),
                    ),
                    items.length > 0
                      ? h(
                          'div',
                          { style: styles.chipRow },
                          items.map(function (item, index) {
                            return h(
                              'span',
                              { key: field.key + '-' + index, style: styles.chip, title: item },
                              h('span', { style: styles.chipText }, item),
                              h(
                                'button',
                                {
                                  'data-dsh-watchdog-chip-remove': field.key,
                                  type: 'button',
                                  disabled: isDisabled,
                                  title: '删除',
                                  'aria-label': '删除 ' + item,
                                  style: styles.chipDelete,
                                  onClick: function () {
                                    onListRemove(field, index);
                                  },
                                },
                                'x',
                              ),
                            );
                          }),
                        )
                      : null,
                  );
                }

                function renderField(field, first) {
                  if (field.type === 'select') return renderSelectRow(field, first);
                  if (field.type === 'list') return renderListField(field, first);
                  if (field.type === 'kinds') return renderKindField(field, first);
                  if (field.type === 'bool') return renderBoolRow(field, first);
                  return renderNumberRow(field, first);
                }

                function renderGroup(group) {
                  return h(
                    'section',
                    { key: group.id, style: styles.card },
                    h('div', { style: styles.cardTitle }, group.title),
                    group.hint ? h('div', { style: styles.cardHint }, group.hint) : null,
                    group.fields.map(function (field, index) {
                      return renderField(field, index === 0);
                    }),
                  );
                }

                if (status === 'loading' && !form) {
                  return h(
                    'div',
                    { 'data-dsh-watchdog-settings': '1', style: styles.root },
                    h('div', { style: styles.heading }, '会话哨兵'),
                    h('div', { style: styles.subtitle }, '正在读取配置…'),
                  );
                }

                if (status === 'error' && !form) {
                  return h(
                    'div',
                    { 'data-dsh-watchdog-settings': '1', style: styles.root },
                    h('div', { style: styles.heading }, '会话哨兵'),
                    h(
                      'div',
                      { style: Object.assign({}, styles.card, { borderColor: palette.danger }) },
                      h(
                        'div',
                        { style: { fontSize: '12px', color: palette.danger } },
                        errorText === '' ? '读取配置失败' : errorText,
                      ),
                      h(
                        'div',
                        { style: { marginTop: '8px' } },
                        h(
                          'button',
                          {
                            'data-dsh-watchdog-retry': '1',
                            type: 'button',
                            style: styles.smallButton,
                            onClick: onRetry,
                          },
                          '重试',
                        ),
                      ),
                    ),
                  );
                }

                const noticeText = notice && typeof notice.text === 'string' ? notice.text : '';
                const noticeColor = notice && notice.kind === 'error'
                  ? palette.danger
                  : notice && notice.kind === 'ok'
                    ? palette.success
                    : palette.muted;
                const footer = dirty.count > 0 || confirmReset === true
                  ? h(
                      'div',
                      { style: styles.footer },
                      h(
                        'button',
                        {
                          'data-dsh-watchdog-save': '1',
                          type: 'button',
                          disabled: busy,
                          style: busy ? Object.assign({}, styles.primaryButton, styles.disabledButton) : styles.primaryButton,
                          onClick: onSubmitSave,
                        },
                        busy ? '保存中…' : '保存',
                      ),
                      h(
                        'button',
                        {
                          'data-dsh-watchdog-reset': '1',
                          type: 'button',
                          disabled: busy,
                          style: Object.assign(
                            {},
                            confirmReset === true ? styles.dangerButton : styles.ghostButton,
                            busy ? styles.disabledButton : null,
                          ),
                          onClick: onResetClick,
                        },
                        confirmReset === true ? '再点一次确认' : '恢复默认',
                      ),
                      dirty.count > 0
                        ? h('span', { style: styles.meta }, '待提交 ' + dirty.count + ' 项改动')
                        : null,
                    )
                  : null;
                const metaLine = meta.updatedAt > 0
                  ? '上次保存：' + formatClock(meta.updatedAt) + ' · 修改后点「保存」立即生效。'
                  : '配置由宿主保存，修改后点「保存」立即生效，无需重启。';

                return h(
                  'div',
                  { 'data-dsh-watchdog-settings': '1', style: styles.root },
                  h(
                    'div',
                    { style: { marginBottom: '12px' } },
                    h('div', { style: styles.heading }, '会话哨兵'),
                    h(
                      'div',
                      { style: styles.subtitle },
                      '会话异常停止时提醒并自动续跑；这里改的配置保存后立即生效，无需重启 DSH。',
                    ),
                  ),
                  SETTINGS_GROUPS.map(renderGroup),
                  footer,
                  noticeText !== ''
                    ? h(
                        'div',
                        {
                          'data-dsh-watchdog-notice': notice && notice.kind ? notice.kind : 'info',
                          style: { marginTop: '8px', fontSize: '12px', color: noticeColor },
                        },
                        noticeText,
                      )
                    : null,
                  h('div', { style: styles.meta }, metaLine),
                );
              };
            }

            // ────────────── 右上角提醒卡片 ──────────────

            /**
             * 确保浮层容器存在。
             *
             * 落点选择：**直接 append 到 body 的 fixed 容器**，不用 shell.overlay 槽。
             * 理由：本插件的 exports.inject 按任务契约固定为 ['uiSession']，拿不到 slots 服务就没法
             * 注册 React 组件；而报告 §3a 路 B / §6.2 也把"自建浮层"列为等价保底方案
             * （02-ui-alert.md:669-682）。纯 DOM 实现零依赖、无需 React/primitives、卸载时整棵移除，
             * 同时避开 §6.3 坑 3（list 槽必须 id）与坑 8（模块体副作用延迟）。
             * 容器 pointer-events:none，卡片自身 pointer-events:auto，不遮挡宿主界面点击。
             */
            function ensureOverlay() {
              try {
                if (state.overlay && state.overlay.parentNode) return state.overlay;
                if (typeof document === 'undefined') return null;
                const host = document.body || document.documentElement;
                if (!host) return null;
                const overlay = document.createElement('div');
                overlay.setAttribute('data-dsh-watchdog-overlay', '1');
                Object.assign(overlay.style, {
                  position: 'fixed',
                  bottom: '12px',
                  right: '12px',
                  zIndex: '2147483647',
                  display: 'flex',
                  flexDirection: 'column-reverse',
                  alignItems: 'flex-end',
                  gap: '8px',
                  pointerEvents: 'none',
                  maxWidth: 'calc(100vw - 24px)',
                });
                host.appendChild(overlay);
                state.overlay = overlay;
                return overlay;
              } catch (error) {
                warn('创建提醒浮层失败（已隔离）', error);
                return null;
              }
            }

            /**
             * 解析会话显示名：与会话列表保持完全一致（列表 displayTitle = title ?? cwd 目录名 ?? id）。
             * 宿主提醒 title 可能为空（插件加载晚 / 标题事件在 400 条窗口外），这里以列表为准兜底；
             * 也兼容旧宿主可能下发的「未命名会话」占位。
             */
            function resolveSessionTitle(sessionId, fallbackTitle) {
              try {
                const raw = typeof fallbackTitle === 'string' ? fallbackTitle.trim() : ''
                if (raw !== '' && raw !== '未命名会话') return raw
                const sessions = readService(scope, 'sessions')
                const list = sessions && sessions.list
                const snapshot = list && typeof list.getSnapshot === 'function' ? list.getSnapshot() : list
                const row = snapshot && snapshot.byId ? snapshot.byId[sessionId] : null
                if (row) {
                  const title = typeof row.displayTitle === 'string' && row.displayTitle ? row.displayTitle : (typeof row.title === 'string' ? row.title : '')
                  if (title) return title
                }
              } catch (error) {
                /* 列表暂不可用：退回短 id，绝不显示「未命名」 */
              }
              return '会话 ' + String(sessionId || '').slice(0, 8)
            }

            /** 有卡片就排队，没超上限就直接显示。 */
            function enqueueCard(alert) {
              try {
                if (state.stopped) return;
                for (const card of state.cards) {
                  if (card.alert.id === alert.id) return;
                }
                for (const queued of state.queue) {
                  if (queued.id === alert.id) return;
                }
                if (state.cards.length >= MAX_CARDS) {
                  if (state.queue.length >= MAX_QUEUE) state.queue.shift();
                  state.queue.push(alert);
                  return;
                }
                showCard(alert);
              } catch (error) {
                warn('排队提醒失败（已隔离）', error);
              }
            }

            /** 真正把卡片塞进浮层；返回是否成功。 */
            function showCard(alert) {
              try {
                if (state.stopped) return false;
                const overlay = ensureOverlay();
                if (!overlay) {
                  if (state.queue.length < MAX_QUEUE) state.queue.push(alert);
                  return false;
                }
                const card = buildCard(alert);
                if (!card) return false;
                state.cards.push(card);
                overlay.appendChild(card.el);
                armCardTimer(card);
                // 入场动画（requestAnimationFrame 不可用时直接显示）
                try {
                  card.el.style.opacity = '0';
                  card.el.style.transform = 'translateY(-6px)';
                  if (typeof requestAnimationFrame === 'function') {
                    requestAnimationFrame(() => {
                      try {
                        card.el.style.opacity = '1';
                        card.el.style.transform = 'translateY(0)';
                      } catch (error) {
                        /* 忽略 */
                      }
                    });
                  } else {
                    card.el.style.opacity = '1';
                    card.el.style.transform = 'translateY(0)';
                  }
                } catch (error) {
                  /* 动画失败不影响显示 */
                }
                return true;
              } catch (error) {
                warn('显示提醒卡片失败（已隔离）', error);
                return false;
              }
            }

            /** 超时自动移除（toastDurationMs）。鼠标悬停时暂停计时，方便看按钮。 */
            function armCardTimer(card) {
              try {
                if (card.timer !== undefined) {
                  clearTimeout(card.timer);
                  card.timer = undefined;
                }
                const raw = Number(state.config.toastDurationMs);
                const duration = Math.min(60000, Math.max(2000, Number.isFinite(raw) ? raw : DEFAULT_CONFIG.toastDurationMs));
                card.timer = setTimeout(() => {
                  removeCard(card.alert.id, 'timeout');
                }, duration);
              } catch (error) {
                /* 定时器不可用：卡片不自动消失，用户仍可点按钮 */
              }
            }

            /** 组装一张卡片（纯 DOM，不引 primitives / 不注入全局 CSS）。 */
            function buildCard(alert) {
              try {
                const level = levelOf(alert);
                const color = LEVEL_COLOR[level] || LEVEL_COLOR.error;
                const el = document.createElement('div');
                el.setAttribute('data-dsh-watchdog-card', '1');
                el.setAttribute('data-alert-id', alert.id);
                el.setAttribute('data-dsh-watchdog-card-kind', alert.kind);
                el.setAttribute('role', 'alert');
                el.setAttribute('aria-live', 'polite');
                Object.assign(el.style, {
                  pointerEvents: 'auto',
                  width: CARD_WIDTH + 'px',
                  maxWidth: 'calc(100vw - 32px)',
                  boxSizing: 'border-box',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: '6px',
                  padding: '10px 12px',
                  borderRadius: '10px',
                  background: 'rgba(28, 28, 34, 0.97)',
                  color: '#f1f1f4',
                  border: '1px solid rgba(255, 255, 255, 0.14)',
                  borderLeft: '3px solid ' + color,
                  boxShadow: '0 10px 30px rgba(0, 0, 0, 0.38)',
                  fontFamily: '"Segoe UI", system-ui, -apple-system, sans-serif',
                  fontSize: '12px',
                  lineHeight: '1.5',
                  transition: 'opacity .18s ease, transform .18s ease',
                  opacity: '1',
                  transform: 'translateY(0)',
                  userSelect: 'none',
                });

                // 第一行：状态点 + 会话标题 + 时间
                const head = document.createElement('div');
                Object.assign(head.style, { display: 'flex', alignItems: 'center', gap: '6px' });
                const dot = document.createElement('span');
                Object.assign(dot.style, {
                  width: '8px',
                  height: '8px',
                  borderRadius: '50%',
                  background: color,
                  flex: 'none',
                });
                const title = document.createElement('span');
                title.textContent = truncateText(resolveSessionTitle(alert.sessionId, alert.title), 48);
                Object.assign(title.style, {
                  flex: '1',
                  minWidth: '0',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                  fontWeight: '600',
                });
                const time = document.createElement('span');
                time.textContent = formatClock(alert.at);
                Object.assign(time.style, { flex: 'none', color: '#a1a1aa', fontVariantNumeric: 'tabular-nums' });
                head.appendChild(dot);
                head.appendChild(title);
                head.appendChild(time);
                el.appendChild(head);

                // 第二行：原因中文标签 · 阶段 · 轮次 · 续跑次数（stage 变化时 refreshCardAlert 会重写）
                const meta = document.createElement('div');
                meta.textContent = metaTextOf(alert);
                Object.assign(meta.style, { color: '#a1a1aa' });
                el.appendChild(meta);

                // 第三行：错误摘要 / 原因（最多 3 行）
                const detail = document.createElement('div');
                detail.textContent = describeAlert(alert);
                Object.assign(detail.style, {
                  color: '#d4d4d8',
                  maxHeight: '54px',
                  overflow: 'hidden',
                  display: '-webkit-box',
                  WebkitLineClamp: '3',
                  WebkitBoxOrient: 'vertical',
                  wordBreak: 'break-word',
                });
                el.appendChild(detail);

                // 第四行：提示 + 按钮
                const actions = document.createElement('div');
                Object.assign(actions.style, { display: 'flex', alignItems: 'center', gap: '8px', marginTop: '2px' });
                const status = document.createElement('span');
                Object.assign(status.style, {
                  flex: '1',
                  minWidth: '0',
                  color: '#a1a1aa',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                });
                actions.appendChild(status);

                const card = { alert: alert, el: el, timer: undefined, status: status, metaEl: meta, resumeButton: undefined };

                // 「续跑」按钮：只有异常提醒才有；任务完成提醒只给「忽略」（完成不需要也不会续跑）
                if (alert.kind !== 'completed') {
                  // 续跑中/已恢复时禁用（stage 推进由 refreshCardAlert 同步）
                  const resumable = alert.stage !== 'resuming' && alert.stage !== 'resumed';
                  const resume = document.createElement('button');
                  resume.type = 'button';
                  resume.textContent = '续跑';
                  resume.disabled = !resumable;
                  resume.style.opacity = resumable ? '' : '0.5';
                  styleButton(resume, true);
                  resume.addEventListener('click', (event) => {
                    try {
                      event.preventDefault();
                      event.stopPropagation();
                    } catch (error) {
                      /* 忽略 */
                    }
                    void handleCardAction(card, 'resume', resume);
                  });
                  actions.appendChild(resume);
                  card.resumeButton = resume;
                }

                const dismiss = document.createElement('button');
                dismiss.type = 'button';
                dismiss.textContent = '忽略';
                styleButton(dismiss, false);
                dismiss.addEventListener('click', (event) => {
                  try {
                    event.preventDefault();
                    event.stopPropagation();
                  } catch (error) {
                    /* 忽略 */
                  }
                  void handleCardAction(card, 'dismiss', dismiss);
                });
                actions.appendChild(dismiss);

                el.appendChild(actions);

                // 悬停暂停自动消失
                el.addEventListener('mouseenter', () => {
                  try {
                    if (card.timer !== undefined) {
                      clearTimeout(card.timer);
                      card.timer = undefined;
                    }
                  } catch (error) {
                    /* 忽略 */
                  }
                });
                el.addEventListener('mouseleave', () => {
                  armCardTimer(card);
                });

                return card;
              } catch (error) {
                warn('组装提醒卡片失败（已隔离）', error);
                return null;
              }
            }

            /** 找到某条 alert 正在显示的卡片。 */
            function findCard(alertId) {
              try {
                for (const card of state.cards) {
                  if (card.alert.id === alertId) return card;
                }
              } catch (error) {
                /* 忽略 */
              }
              return null;
            }

            /**
             * 同一条 alert 的 stage 推进（如自动续跑 detected → resuming → resumed）：
             * 同步已显示卡片的第二行文案、「续跑」按钮可用性与状态提示，不重复弹卡片。
             */
            function refreshCardAlert(card, alert) {
              try {
                if (!card) return;
                card.alert = alert;
                if (card.metaEl) card.metaEl.textContent = metaTextOf(alert);
                const resumable = alert.stage !== 'resuming' && alert.stage !== 'resumed';
                if (card.resumeButton) {
                  card.resumeButton.disabled = !resumable;
                  card.resumeButton.style.opacity = resumable ? '' : '0.5';
                }
                if (alert.kind === 'completed') setCardStatus(card, '已完成');
                else if (alert.stage === 'resuming') setCardStatus(card, '宿主正在续跑…');
                else if (alert.stage === 'resumed') setCardStatus(card, '已恢复');
                else if (alert.stage === 'resume-failed') setCardStatus(card, '续跑失败');
              } catch (error) {
                /* 忽略 */
              }
            }

            function setCardStatus(card, text) {
              try {
                if (!card || !card.status) return;
                card.status.textContent = text;
              } catch (error) {
                /* 忽略 */
              }
            }

            /** 卡片按钮：POST 宿主 action，成功才移除卡片（失败给出可重试提示）。 */
            async function handleCardAction(card, action, button) {
              try {
                if (!card || !card.alert) return;
                const alert = card.alert;
                if (button) {
                  button.disabled = true;
                  button.style.opacity = '0.6';
                }
                setCardStatus(card, action === 'resume' ? '正在提交续跑…' : '正在忽略…');
                const ok = await postAction(alert, action);
                if (state.stopped) return;
                if (!ok) {
                  if (button) {
                    button.disabled = false;
                    button.style.opacity = '';
                  }
                  setCardStatus(card, '请求失败，请稍后重试');
                  return;
                }
                if (action === 'resume') {
                  // 乐观更新：宿主下一次 alerts 会带回真实 stage
                  setBadge(alert.sessionId, {
                    level: 'resuming',
                    label: '会话哨兵：续跑中（' + kindLabel(alert.kind) + '）',
                    at: Date.now(),
                    alertId: alert.id,
                  });
                } else {
                  state.alerts.delete(alert.id);
                  clearBadge(alert.sessionId, alert.id);
                }
                removeCard(alert.id, action);
              } catch (error) {
                warn('提醒卡片操作失败（已隔离）', error);
              }
            }

            /** POST /dsh-session-watchdog/action { id, action }。 */
            async function postAction(alert, action) {
              try {
                const response = await fetchWithTimeout(ACTION_URL, {
                  method: 'POST',
                  headers: { 'content-type': 'application/json', accept: 'application/json' },
                  body: JSON.stringify({ id: alert.id, action: action }),
                });
                if (!response || response.ok !== true) return false;
                let payload = null;
                try {
                  payload = await response.json();
                } catch (error) {
                  payload = null;
                }
                if (payload && typeof payload === 'object' && payload.ok === false) return false;
                return true;
              } catch (error) {
                return false;
              }
            }

            /** 移除一张卡片（带淡出），并从队列补位。 */
            function removeCard(alertId, reason) {
              try {
                let index = -1;
                for (let cursor = 0; cursor < state.cards.length; cursor += 1) {
                  if (state.cards[cursor].alert.id === alertId) {
                    index = cursor;
                    break;
                  }
                }
                if (index < 0) return;
                const card = state.cards[index];
                state.cards.splice(index, 1);
                if (card.timer !== undefined) {
                  try {
                    clearTimeout(card.timer);
                  } catch (error) {
                    /* 忽略 */
                  }
                  card.timer = undefined;
                }
                const el = card.el;
                try {
                  el.style.opacity = '0';
                  el.style.transform = 'translateY(-6px)';
                } catch (error) {
                  /* 忽略 */
                }
                setTimeout(() => {
                  try {
                    if (el.parentNode) el.parentNode.removeChild(el);
                  } catch (error) {
                    /* 忽略 */
                  }
                }, 200);
                drainQueue();
              } catch (error) {
                warn('移除提醒卡片失败（已隔离）', error);
              }
            }

            /** 把排队中的提醒补到空位。 */
            function drainQueue() {
              try {
                while (!state.stopped && state.queue.length > 0 && state.cards.length < MAX_CARDS) {
                  const next = state.queue.shift();
                  if (!next) break;
                  const shown = showCard(next);
                  if (!shown) break;
                }
              } catch (error) {
                warn('补位提醒失败（已隔离）', error);
              }
            }

            /** 卸掉整个浮层与所有卡片定时器。 */
            function removeOverlay() {
              try {
                const overlay = state.overlay;
                state.overlay = null;
                for (const card of state.cards) {
                  if (card.timer !== undefined) {
                    try {
                      clearTimeout(card.timer);
                    } catch (error) {
                      /* 忽略 */
                    }
                    card.timer = undefined;
                  }
                  try {
                    if (card.el && card.el.parentNode) card.el.parentNode.removeChild(card.el);
                  } catch (error) {
                    /* 忽略 */
                  }
                }
                state.cards.length = 0;
                state.queue.length = 0;
                if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
              } catch (error) {
                /* 清理尽力而为 */
              }
            }

            // ────────────── 前后台切换 ──────────────

            function onVisibilityChange() {
              try {
                if (state.stopped) return;
                if (documentIsHidden()) {
                  scheduleTick(state.backoff > 0 ? backoffDelay() : POLL_HIDDEN_MS);
                  return;
                }
                // 回到前台：配置可能改过，顺便刷新一次
                if (!state.configLoaded && Date.now() - state.lastConfigAttemptAt > CONFIG_RETRY_MS) {
                  state.lastConfigAttemptAt = Date.now();
                  void loadConfig();
                }
                scheduleTick(300);
              } catch (error) {
                /* 事件监听内部错误绝不外抛 */
              }
            }

            // ────────────── 排障入口 ──────────────

            /** 控制台可查状态（window.__dshSessionWatchdog），方便现场确认「插件到底有没有跑」。 */
            function installDiagnostics() {
              try {
                if (typeof window === 'undefined') return;
                const api = {
                  version: '0.1.0',
                  alerts: () =>
                    Array.from(state.alerts.values()).map((alert) => ({
                      id: alert.id,
                      sessionId: alert.sessionId,
                      kind: alert.kind,
                      stage: alert.stage,
                    })),
                  config: () => Object.assign({}, state.config),
                  badges: () => Array.from(state.badgeStates.entries()),
                  cards: () => state.cards.map((card) => card.alert.id),
                  /** 提示音排障：是否支持、上下文状态、已播放次数 / 上次音色与音量 */
                  sound: () => soundEngine.snapshot(),
                  cursor: () => state.cursor,
                  poll: () => {
                    scheduleTick(0);
                    return 'scheduled';
                  },
                };
                state.diagnostic = api;
                window.__dshSessionWatchdog = api;
              } catch (error) {
                /* 排障入口失败无所谓 */
              }
            }

            // ────────────── 生命周期 ──────────────

            function start() {
              if (state.started) return;
              state.started = true;
              try {
                prepareNotifications();
              } catch (error) {
                warn('初始化通知权限失败（已忽略）', error);
              }
              try {
                installSoundUnlock();
              } catch (error) {
                warn('注册音频解锁监听失败（已忽略）', error);
              }
              try {
                installBadgeSlot();
              } catch (error) {
                warn('安装侧栏徽标失败（已忽略）', error);
              }
              try {
                installSettingsSlot();
              } catch (error) {
                warn('安装设置页失败（已忽略）', error);
              }
              try {
                installDiagnostics();
              } catch (error) {
                warn('安装排障入口失败（已忽略）', error);
              }
              try {
                if (typeof document !== 'undefined' && typeof document.addEventListener === 'function') {
                  document.addEventListener('visibilitychange', onVisibilityChange);
                  state.disposers.push(() => {
                    try {
                      document.removeEventListener('visibilitychange', onVisibilityChange);
                    } catch (error) {
                      /* 忽略 */
                    }
                  });
                }
              } catch (error) {
                warn('注册前后台监听失败（已忽略）', error);
              }
              try {
                state.lastConfigAttemptAt = Date.now();
                void loadConfig();
              } catch (error) {
                /* 配置读取失败会按默认值继续 */
              }
              try {
                scheduleTick(0);
              } catch (error) {
                warn('启动轮询失败（已忽略）', error);
              }
            }

            function dispose() {
              if (state.stopped) return;
              state.stopped = true;
              try {
                if (state.pollTimer !== undefined) clearTimeout(state.pollTimer);
              } catch (error) {
                /* 忽略 */
              }
              state.pollTimer = undefined;
              for (const disposer of state.disposers.splice(0)) {
                try {
                  disposer();
                } catch (error) {
                  /* 单个清理失败不影响其余 */
                }
              }
              for (const timer of Array.from(state.badgeTimers.values())) {
                try {
                  clearTimeout(timer);
                } catch (error) {
                  /* 忽略 */
                }
              }
              state.badgeTimers.clear();
              try {
                removeOverlay();
              } catch (error) {
                /* 忽略 */
              }
              for (const notification of Array.from(state.notifications)) {
                try {
                  notification.close();
                } catch (error) {
                  /* 忽略 */
                }
              }
              state.notifications.clear();
              try {
                state.badgeListeners.clear();
              } catch (error) {
                /* 忽略 */
              }
              try {
                soundEngine.dispose();
              } catch (error) {
                /* 忽略 */
              }
              try {
                state.alerts.clear();
                state.toasted.clear();
                state.sounded.clear();
                state.badgeStates.clear();
                state.queue.length = 0;
              } catch (error) {
                /* 忽略 */
              }
              try {
                if (typeof window !== 'undefined' && window.__dshSessionWatchdog === state.diagnostic) {
                  delete window.__dshSessionWatchdog;
                }
              } catch (error) {
                /* 忽略 */
              }
            }

            return { start: start, dispose: dispose };
          }

          return apply;
        }

        // ────────────────────────────────────────────────────────────────────
        // 导出（即使构造失败也要给出合法形状，避免拖垮宿主 UI）
        // ────────────────────────────────────────────────────────────────────
        exports.inject = inject;
        try {
          exports.apply = createClientApply(require);
        } catch (error) {
          warn('浏览器半侧构建失败，已降级为空插件', error);
          exports.apply = function applyUnavailable() {};
        }
        return module.exports;
      },
    });
  } catch (error) {
    try {
      if (typeof console !== 'undefined' && typeof console.warn === 'function') {
        console.warn('[dsh-session-watchdog] 注册模块工厂失败，浏览器半侧未挂载', error);
      }
    } catch (nested) {
      /* 控制台不可用 */
    }
  }
} else {
  try {
    if (typeof console !== 'undefined' && typeof console.warn === 'function') {
      console.warn('[dsh-session-watchdog] DSH 客户端模块加载器不可用（window.__ModuleLoader__ 缺失），浏览器半侧未挂载');
    }
  } catch (error) {
    /* 控制台不可用 */
  }
}
