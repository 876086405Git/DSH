/* DSH体检中心 — 设置面板
 *
 * 挂载位置：「设置 → 插件 → dsh-checkup」（plugins.bundle.config 槽）。
 * 结构：总览 / 拦截设置 / 检查规则 / 包源与读取 / 黑名单 / 手动预检 / 最近记录。
 * 可改项与 lib/index.js 的 settings 一一对应（preflightEnabled / blockOnWarn /
 * registries / lookupTimeoutMs / lookupAttempts / knownBad），保存即写回 profile 的
 * cordis.patch.yml 并立即生效；规则与历史只读。
 */
window.__ModuleLoader__.load({
  id: 'dsh-checkup',
  factory: (require) => {
    const module = { exports: {} };
    const exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });

    const React = require('react');
    const { useState, useEffect, useCallback, useMemo, useRef } = React;
    const h = React.createElement;

    const name = 'checkup';
    const inject = ['slots'];

    const C = {
      text: 'var(--dsh-text, #e8e8ea)',
      dim: 'var(--dsh-text-secondary, #9a9aa2)',
      border: 'var(--dsh-border, rgba(255,255,255,.12))',
      card: 'var(--dsh-surface, rgba(255,255,255,.04))',
      block: '#ff6b6b',
      warn: '#f0b429',
      pass: '#3ecf8e',
      accent: 'var(--dsh-accent, #4c8dff)',
    };

    const LEVEL_LABEL = { block: '阻止安装', warn: '仅提醒', pass: '通过' };

    // 三大分类：检查项、结果分组、面板规则表都按它组织。
    const CATEGORY_ORDER = ['compatibility', 'security', 'stability'];
    const CATEGORY_INFO = {
      compatibility: { label: '兼容性', desc: '能否在当前 DSH 客户端环境正确加载与运行' },
      security: { label: '安全性', desc: '隐私泄露 / 恶意代码 / 病毒代码风险' },
      stability: { label: '稳定性', desc: '运行是否稳定，是否存在潜在 bug 与维护风险' },
    };

    const RULE_INFO = {
      // 兼容性
      spec: ['兼容性', '安装目标', '解析包名、版本、本地路径或 git/tarball 形式'],
      'manifest-unavailable': ['兼容性', '包元数据', '拿不到 package.json（断网 / 查无此包 / git 形式）等于零预检，默认阻止安装'],
      'runtime-version': ['兼容性', '客户端版本兼容', '比对插件声明的 dsh.engines.dsh 与当前桌面端版本'],
      'node-engine': ['兼容性', 'Node 运行时', '比对 engines.node 与桌面端内置 Node 版本'],
      'client-platform': ['兼容性', '客户端平台', '只接受 web 平台（桌面端不加载其他平台）'],
      'client-inject': ['兼容性', '客户端注入依赖', '逐项核对 dsh.client.inject 的包在当前版本是否存在（boot 崩溃主因）'],
      'bundle-declared': ['兼容性', 'bundle 声明', 'dsh.bundle.patch 路径必须存在'],
      'peer-deps': ['兼容性', 'peer 依赖', '逐条列出当前版本与要求版本'],
      'known-bad': ['兼容性', '崩溃黑名单', '命中则直接阻止安装'],
      duplicate: ['兼容性', '重复安装', '包已在 profile bundles 中时提醒'],
      'bundle-load': ['兼容性', 'bundle 数量', '接近软上限时提醒，避免 boot 失败后难定位'],
      // 交叉比对（候选 vs 已装）
      'dup-plugin-version': ['兼容性', '同名包版本比对', '已装同名包时比版本：升级 / 降级 / 换版，避免覆盖错副本'],
      'conflict-deps': ['兼容性', '依赖排斥', '候选的 dependencies 与本地已装版本是否互斥（宿主单例包装出第二份实例会静默失效）'],
      'dup-connector-name': ['稳定性', '连接器重名', '与已配置连接器的 serverName 撞车，工具前缀会互相覆盖'],
      'conflict-connector-tool': ['稳定性', '连接器工具冲突', '同一后端换名字重复接入，或名字只差大小写/分隔符'],
      'dup-skill-content': ['稳定性', '技能内容重复', '改名重装同一份技能（SKILL.md 正文指纹或 frontmatter name 撞车）'],
      'cand-expert-shape': ['兼容性', '专家预设结构', 'id 前缀 / 名称 / 人设正文是否完整'],
      'cand-expert-dup': ['稳定性', '专家重复', '与已装专家撞 id / 撞名 / 同一套人设换个名字'],
      'cand-expert-refs': ['稳定性', '专家引用插件', '专家引用的第三方插件是否已安装'],
      // 安全性
      'sec-manifest': ['安全性', '包元数据', '拿不到 package.json 时无法扫描安装脚本与依赖'],
      'sec-scripts': ['安全性', '安装脚本', '检查 preinstall/install/postinstall 里的下载即执行、编码执行、LOLBin 加载'],
      'sec-deps': ['安全性', '恶意依赖名单', '依赖命中名单即判恶意（可配置）'],
      'sec-typosquat': ['安全性', '包名仿冒', '与已装插件名仅差一个字符，存在抢注/仿冒风险'],
      'sec-source': ['安全性', '源码特征', '读取 SSH/云凭据、浏览器 Cookie、环境变量外传、base64+eval 等'],
      'mal-remote-code': ['安全性', '远程代码执行', '抓到远程/动态内容后交给 eval / new Function 执行'],
      'sec-vulns': ['安全性', '已知漏洞', '按包名+版本查 OSV（GHSA/CVE），高危阻止、其余提醒；查询失败只提醒'],
      'sec-allowlist': ['安全性', '包自带豁免', '包自带 .checkup-allow.json / checkupAllow：只能把阻止降为提醒，不能变成通过'],
      'sec-traceability': ['安全性', '来源可追溯', 'repository 与 author 齐全才便于追责'],
      // 稳定性
      'st-manifest': ['稳定性', '包元数据', '拿不到 package.json 时无法判断入口与依赖负担'],
      'st-entrypoints': ['稳定性', '入口声明', 'dsh.client 必须配 exports["./client"]，否则启动失败'],
      'st-version': ['稳定性', '版本成熟度', '0.0.x 与预发布版本的接口可能随时变化'],
      'st-deps-weight': ['稳定性', '依赖负担', '运行时依赖数量过多会增加冲突面'],
      'st-package-size': ['稳定性', '包体积', '过大的包下载/解包更容易失败'],
      'st-maintenance': ['稳定性', '维护信息', 'license/repository/test 缺失意味着维护信号弱'],
      'st-engine-declared': ['稳定性', 'Node 版本声明', 'engines.node 缺失时无法预判运行时匹配'],
    };

    function categoryOf(id) {
      const row = RULE_INFO[id];
      if (row && row[0]) {
        return row[0] === '安全性' ? 'security' : row[0] === '稳定性' ? 'stability' : 'compatibility';
      }
      return 'compatibility';
    }

    function groupChecks(checks) {
      const groups = { compatibility: [], security: [], stability: [] };
      for (const check of checks || []) {
        const key = check.category && groups[check.category] ? check.category : categoryOf(check.id);
        groups[key].push(check);
      }
      return groups;
    }

    function categoryStats(rows) {
      return {
        total: rows.length,
        blocked: rows.filter((r) => r.level === 'block').length,
        warned: rows.filter((r) => r.level === 'warn').length,
        passed: rows.filter((r) => r.level === 'pass').length,
      };
    }

    // ── 基础控件 ────────────────────────────────────────────────────────────

    // 哨兵事件 → 一句话描述（动作中文 + 关键检查项）。
    function sentinelActionLabel(event) {
      const ids = (event.blockedIds || []).join('、');
      switch (event.action) {
        case 'quarantined':
          return `已隔离到隔离区（${ids || 'block 级问题'}）`;
        case 'quarantine-failed':
          return `隔离失败（目录被占用？请手动处理）— ${ids}`;
        case 'released':
          return '已放行回 skill 根';
        case 'deleted':
          return '已从隔离区删除';
        case 'removed':
          return `已从 profile patch 摘除（${ids}）`;
        case 'remove-failed':
          return `摘除失败（已保留原样，请人工处理）— ${ids}`;
        case 'warn-only':
          return `仅告警未拦截 — ${ids}`;
        case 'passed':
          return event.warned > 0 ? `通过（${event.warned} 项提醒）` : '通过';
        default:
          return event.action;
      }
    }

    function Card({ title, desc, children, badge }) {
      return h(
        'section',
        {
          style: {
            border: `1px solid ${C.border}`,
            borderRadius: 10,
            background: C.card,
            padding: '14px 16px',
            marginBottom: 12,
          },
        },
        h(
          'div',
          { style: { display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: desc ? 4 : 10 } },
          h('div', { style: { fontSize: 14, fontWeight: 700, color: C.text } }, title),
          badge || null,
        ),
        desc ? h('div', { style: { fontSize: 12, color: C.dim, lineHeight: 1.7, marginBottom: 10 } }, desc) : null,
        children,
      );
    }

    function Toggle({ checked, onChange, disabled }) {
      return h(
        'button',
        {
          type: 'button',
          role: 'switch',
          'aria-checked': checked,
          disabled,
          onClick: () => !disabled && onChange(!checked),
          style: {
            width: 40,
            height: 22,
            borderRadius: 11,
            border: 'none',
            padding: 0,
            flex: 'none',
            cursor: disabled ? 'default' : 'pointer',
            opacity: disabled ? 0.5 : 1,
            background: checked ? C.accent : C.border,
            position: 'relative',
            transition: 'background .12s ease',
          },
        },
        h('span', {
          style: {
            position: 'absolute',
            top: 2,
            left: checked ? 20 : 2,
            width: 18,
            height: 18,
            borderRadius: '50%',
            background: '#fff',
            transition: 'left .12s ease',
          },
        }),
      );
    }

    function Row({ label, desc, children }) {
      return h(
        'div',
        {
          style: {
            display: 'flex',
            alignItems: 'flex-start',
            justifyContent: 'space-between',
            gap: 16,
            padding: '10px 0',
            borderTop: `1px solid ${C.border}`,
          },
        },
        h(
          'div',
          { style: { minWidth: 0 } },
          h('div', { style: { fontSize: 13, fontWeight: 600, color: C.text } }, label),
          desc ? h('div', { style: { fontSize: 12, color: C.dim, marginTop: 3, lineHeight: 1.6 } }, desc) : null,
        ),
        h('div', { style: { flex: 'none', display: 'flex', alignItems: 'center', gap: 8 } }, children),
      );
    }

    function TextInput({ value, onChange, placeholder, width, type }) {
      return h('input', {
        type: type || 'text',
        value,
        placeholder,
        onChange: (event) => onChange(event.target.value),
        style: {
          width: width || 160,
          // box-sizing + min-width 0：宽度按 border-box 计，且放进 grid/flex 里能被压缩，
          // 否则固定像素宽度会撑破容器（MCP 表单那次溢出的直接原因）。
          boxSizing: 'border-box',
          minWidth: 0,
          maxWidth: '100%',
          padding: '7px 10px',
          borderRadius: 7,
          border: `1px solid ${C.border}`,
          background: 'rgba(0,0,0,.18)',
          color: C.text,
          fontSize: 12,
          outline: 'none',
        },
      });
    }

    function SmallButton({ children, onClick, tone, disabled }) {
      const bg = tone === 'danger' ? 'rgba(255,107,107,.16)' : tone === 'primary' ? C.accent : 'rgba(255,255,255,.08)';
      const color = tone === 'primary' ? '#fff' : tone === 'danger' ? C.block : C.text;
      return h(
        'button',
        {
          type: 'button',
          onClick,
          disabled,
          style: {
            padding: '6px 12px',
            borderRadius: 7,
            border: `1px solid ${C.border}`,
            background: bg,
            color,
            fontSize: 12,
            fontWeight: 600,
            cursor: disabled ? 'default' : 'pointer',
            opacity: disabled ? 0.5 : 1,
          },
        },
        children,
      );
    }

    function ListEditor({ items, onChange, placeholder, hint }) {
      const [draft, setDraft] = useState('');
      const add = () => {
        const value = draft.trim();
        if (!value) return;
        if (!items.includes(value)) onChange([...items, value]);
        setDraft('');
      };
      return h(
        'div',
        { style: { display: 'flex', flexDirection: 'column', gap: 6, width: '100%' } },
        items.length === 0
          ? h('div', { style: { fontSize: 12, color: C.dim } }, '（空）')
          : items.map((item, index) =>
              h(
                'div',
                {
                  key: `${item}-${index}`,
                  style: {
                    display: 'flex',
                    alignItems: 'center',
                    gap: 8,
                    padding: '6px 10px',
                    borderRadius: 6,
                    background: 'rgba(0,0,0,.16)',
                    border: `1px solid ${C.border}`,
                    fontSize: 12,
                  },
                },
                h('span', { style: { flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, item),
                index > 0
                  ? h(
                      'button',
                      {
                        type: 'button',
                        title: '上移',
                        onClick: () => {
                          const next = [...items];
                          [next[index - 1], next[index]] = [next[index], next[index - 1]];
                          onChange(next);
                        },
                        style: { border: 'none', background: 'transparent', color: C.dim, cursor: 'pointer', fontSize: 12 },
                      },
                      '↑',
                    )
                  : null,
                h(
                  'button',
                  {
                    type: 'button',
                    title: '移除',
                    onClick: () => onChange(items.filter((_, i) => i !== index)),
                    style: { border: 'none', background: 'transparent', color: C.block, cursor: 'pointer', fontSize: 12 },
                  },
                  '✕',
                ),
              ),
            ),
        h(
          'div',
          { style: { display: 'flex', gap: 6, marginTop: 2 } },
          h(TextInput, {
            value: draft,
            onChange: setDraft,
            placeholder,
            width: 260,
          }),
          h(SmallButton, { onClick: add, disabled: !draft.trim() }, '添加'),
        ),
        hint ? h('div', { style: { fontSize: 11, color: C.dim, marginTop: 2 } }, hint) : null,
      );
    }

    function LevelDot({ level }) {
      return h('span', {
        style: {
          display: 'inline-block',
          width: 8,
          height: 8,
          borderRadius: 4,
          marginRight: 8,
          flex: 'none',
          background: level === 'block' ? C.block : level === 'warn' ? C.warn : C.pass,
        },
      });
    }

    function CheckRows({ checks }) {
      const order = { block: 0, warn: 1, pass: 2 };
      const sorted = [...checks].sort((a, b) => (order[a.level] ?? 9) - (order[b.level] ?? 9));
      return h(
        'div',
        { style: { display: 'flex', flexDirection: 'column', gap: 8 } },
        sorted.map((check, index) =>
          h(
            'div',
            {
              key: `${check.id}-${index}`,
              style: {
                display: 'flex',
                gap: 8,
                padding: '9px 11px',
                borderRadius: 8,
                background: 'rgba(0,0,0,.16)',
                border: `1px solid ${C.border}`,
              },
            },
            h('div', { style: { flex: 'none', paddingTop: 4 } }, h(LevelDot, { level: check.level })),
            h(
              'div',
              { style: { minWidth: 0, flex: 1 } },
              h(
                'div',
                { style: { fontSize: 12, fontWeight: 700, color: C.text } },
                `${check.title} · ${LEVEL_LABEL[check.level] || check.level}`,
              ),
              check.detail
                ? h('div', { style: { fontSize: 12, color: C.dim, marginTop: 3, lineHeight: 1.6 } }, check.detail)
                : null,
              check.hint
                ? h('div', { style: { fontSize: 12, color: C.pass, marginTop: 3, lineHeight: 1.6 } }, `建议：${check.hint}`)
                : null,
            ),
          ),
        ),
      );
    }

    /// 按「兼容性 / 安全性 / 稳定性」分组展示检查结果。
    function CheckList({ checks }) {
      if (!Array.isArray(checks) || checks.length === 0) {
        return h('div', { style: { fontSize: 12, color: C.dim } }, '没有检查项');
      }
      const groups = groupChecks(checks);
      return h(
        'div',
        { style: { display: 'flex', flexDirection: 'column', gap: 14 } },
        CATEGORY_ORDER.filter((key) => groups[key].length > 0).map((key) => {
          const rows = groups[key];
          const stats = categoryStats(rows);
          const info = CATEGORY_INFO[key];
          const tone = stats.blocked > 0 ? C.block : stats.warned > 0 ? C.warn : C.pass;
          return h(
            'div',
            { key },
            h(
              'div',
              {
                style: {
                  display: 'flex',
                  alignItems: 'baseline',
                  gap: 8,
                  marginBottom: 8,
                  paddingBottom: 6,
                  borderBottom: `1px solid ${C.border}`,
                },
              },
              h('span', { style: { fontSize: 13, fontWeight: 700, color: C.text } }, info.label),
              h('span', { style: { fontSize: 11, color: C.dim, flex: 1, minWidth: 0 } }, info.desc),
              h(
                'span',
                { style: { fontSize: 11, color: tone, flex: 'none', fontWeight: 600 } },
                stats.blocked > 0
                  ? `${stats.blocked} 项阻止`
                  : stats.warned > 0
                    ? `${stats.warned} 项提醒`
                    : `${stats.total} 项通过`,
              ),
            ),
            h(CheckRows, { checks: rows }),
          );
        }),
      );
    }

    // ── 数据访问 ────────────────────────────────────────────────────────────

    const getJson = (path) => fetch(path, { cache: 'no-store' }).then((res) => res.json());
    const postJson = (path, body) =>
      fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body || {}),
      }).then((res) => res.json());

    // ── 主面板 ──────────────────────────────────────────────────────────────

    function GuardPanel() {
      const [loading, setLoading] = useState(true);
      const [loadError, setLoadError] = useState(null);
      const [env, setEnv] = useState(null);
      const [rules, setRules] = useState([]);
      const [saved, setSaved] = useState(null); // 服务器上的配置
      const [draft, setDraft] = useState(null); // 面板里的编辑副本
      const [history, setHistory] = useState([]);

      const [saving, setSaving] = useState(false);
      const [saveResult, setSaveResult] = useState(null);

      const [spec, setSpec] = useState('');
      const [checking, setChecking] = useState(false);
      const [report, setReport] = useState(null);

      // 安装流程：idle → checking → checked（通过/未通过）→ installing → done | failed
      const [installSpec, setInstallSpec] = useState('');
      const [installStage, setInstallStage] = useState('idle');
      const [installReport, setInstallReport] = useState(null);
      const [installMessage, setInstallMessage] = useState(null);
      // #1 /check 通过后拿到的一次性 token，安装接口必须带上它。
      const [approvalToken, setApprovalToken] = useState(null);

      // Skill / MCP：没有安装 API，提供「装前检查 + 已装项体检」
      const [skillPath, setSkillPath] = useState('');
      const [skillReport, setSkillReport] = useState(null);
      const [skillBusy, setSkillBusy] = useState(false);
      const [skillMessage, setSkillMessage] = useState(null);
      const [mcpForm, setMcpForm] = useState({ transport: 'stdio', serverName: '', command: '', args: '' });
      const [mcpReport, setMcpReport] = useState(null);
      const [mcpBusy, setMcpBusy] = useState(false);
      const [mcpMessage, setMcpMessage] = useState(null);
      const [inventory, setInventory] = useState(null);
      const [inventoryBusy, setInventoryBusy] = useState(false);

      // 实时拦截哨兵：skill/MCP 落盘兜底拦截的事件与隔离区
      const [guardData, setGuardData] = useState(null);
      const [guardBusy, setGuardBusy] = useState(false);
      const [guardMessage, setGuardMessage] = useState(null);

      // 环境体检：已装插件 / skill / MCP 的保留或卸载建议
      // 军械库四类：连接器 / 技能 / 插件 / 专家
      const [armoryReport, setArmoryReport] = useState(null);
      const [armoryBusy, setArmoryBusy] = useState(false);
      const [armoryMessage, setArmoryMessage] = useState(null);
      const [auditReport, setAuditReport] = useState(null);
      const [auditBusy, setAuditBusy] = useState(false);
      const [auditMessage, setAuditMessage] = useState(null);

      const mounted = useRef(true);

      const applyState = useCallback((data) => {
        if (!data || data.ok !== true) return;
        setEnv(data.env || null);
        setRules(Array.isArray(data.rules) ? data.rules : []);
        setSaved(data.config || null);
        setDraft(data.config ? JSON.parse(JSON.stringify(data.config)) : null);
        setHistory(Array.isArray(data.history) ? data.history : []);
        setLoadError(null);
      }, []);

      const load = useCallback(() => {
        setLoading(true);
        getJson('/api-checkup/state')
          .then((data) => {
            if (!mounted.current) return;
            applyState(data);
            setLoading(false);
          })
          .catch((error) => {
            if (!mounted.current) return;
            setLoadError(String(error));
            setLoading(false);
          });
      }, [applyState]);

      useEffect(() => {
        mounted.current = true;
        load();
        return () => {
          mounted.current = false;
        };
      }, [load]);

      const dirty = useMemo(() => {
        if (!draft || !saved) return false;
        return JSON.stringify(draft) !== JSON.stringify(saved);
      }, [draft, saved]);

      const patch = useCallback((partial) => {
        setDraft((current) => (current ? { ...current, ...partial } : current));
      }, []);

      const save = useCallback(() => {
        if (!draft) return;
        setSaving(true);
        setSaveResult(null);
        postJson('/api-checkup/config', draft)
          .then((data) => {
            if (!mounted.current) return;
            if (data && data.ok === true) {
              setSaved(data.config);
              setDraft(JSON.parse(JSON.stringify(data.config)));
              setSaveResult({ ok: true, message: `已保存（${data.saved === 'appended' ? '新增条目' : '更新条目'}）→ ${data.file}` });
              // 保存成功后底部条只留 2 秒做确认，然后自动收起。
              setTimeout(() => {
                if (mounted.current) setSaveResult(null);
              }, 2000);
              load();
            } else {
              setSaveResult({ ok: false, message: (data && data.error) || '保存失败' });
            }
          })
          .catch((error) => {
            if (mounted.current) setSaveResult({ ok: false, message: String(error) });
          })
          .finally(() => {
            if (mounted.current) setSaving(false);
          });
      }, [draft, load]);

      const reset = useCallback(() => {
        if (!saved) return;
        setDraft(JSON.parse(JSON.stringify(saved)));
        setSaveResult(null);
      }, [saved]);

      const runCheck = useCallback(() => {
        const target = spec.trim();
        if (!target) return;
        setChecking(true);
        postJson('/api-checkup/check', { spec: target })
          .then((data) => {
            if (!mounted.current) return;
            setReport(data && data.report ? data.report : null);
            if (data && data.ok === true) load();
          })
          .catch(() => {
            if (mounted.current) setReport(null);
          })
          .finally(() => {
            if (mounted.current) setChecking(false);
          });
      }, [spec, load]);

      // 安装流程第 1 步：检查（结果留在面板里，不直接跳安装）
      const runInstallCheck = useCallback(() => {
        const target = installSpec.trim();
        if (!target) return;
        setInstallStage('checking');
        setInstallReport(null);
        setInstallMessage(null);
        postJson('/api-checkup/check', { spec: target })
          .then((data) => {
            if (!mounted.current) return;
            const r = data && data.report ? data.report : null;
            setInstallReport(r);
            setApprovalToken(data && typeof data.approvalToken === 'string' ? data.approvalToken : null);
            setInstallStage(r && r.ok ? 'checked' : 'checked');
            load();
          })
          .catch((error) => {
            if (!mounted.current) return;
            setInstallReport(null);
            setInstallStage('failed');
            setInstallMessage(`检查请求失败：${String(error)}`);
          });
      }, [installSpec, load]);

      // 安装流程第 3 步：只有检查通过后才能执行
      const runInstall = useCallback(() => {
        const target = installSpec.trim();
        if (!target) return;
        setInstallStage('installing');
        setInstallMessage(null);
        postJson('/api-checkup/install', { spec: target, token: approvalToken })
          .then((data) => {
            if (!mounted.current) return;
            if (data && data.ok === true) {
              setInstallStage('done');
              setApprovalToken(null);
              setInstallMessage(`已提交安装（${data.result && data.result.detail ? data.result.detail : '宿主动作已接受'}）。重启桌面端后生效。`);
            } else {
              setInstallStage('checked');
              if (data && data.report) setInstallReport(data.report);
              setInstallMessage((data && data.error) || '安装未执行');
            }
            load();
          })
          .catch((error) => {
            if (!mounted.current) return;
            setInstallStage('checked');
            setInstallMessage(`安装请求失败：${String(error)}`);
          });
      }, [installSpec, load]);

      // ── Skill / MCP 检查（它们没有安装 API，只能检查目录与配置）──────────
      const runSkillCheck = useCallback(() => {
        const target = skillPath.trim();
        if (!target) return;
        setSkillBusy(true);
        setSkillMessage(null);
        postJson('/api-checkup/check-skill', { path: target })
          .then((data) => {
            if (!mounted.current) return;
            if (data && data.ok === true) setSkillReport(data.report);
            else {
              setSkillReport(null);
              setSkillMessage((data && data.error) || '检查失败');
            }
          })
          .catch((error) => {
            if (mounted.current) setSkillMessage(String(error));
          })
          .finally(() => {
            if (mounted.current) setSkillBusy(false);
          });
      }, [skillPath]);

      const runMcpCheck = useCallback(() => {
        const config = {
          transport: mcpForm.transport,
          serverName: mcpForm.serverName.trim() || undefined,
          command: mcpForm.command.trim() || undefined,
          args: mcpForm.args.trim() ? mcpForm.args.trim().split(/\s+/) : [],
        };
        setMcpBusy(true);
        setMcpMessage(null);
        postJson('/api-checkup/check-mcp', { config })
          .then((data) => {
            if (!mounted.current) return;
            if (data && data.ok === true) setMcpReport(data.report);
            else {
              setMcpReport(null);
              setMcpMessage((data && data.error) || '检查失败');
            }
          })
          .catch((error) => {
            if (mounted.current) setMcpMessage(String(error));
          })
          .finally(() => {
            if (mounted.current) setMcpBusy(false);
          });
      }, [mcpForm]);

      const runInventory = useCallback(() => {
        setInventoryBusy(true);
        getJson('/api-checkup/inventory')
          .then((data) => {
            if (mounted.current) setInventory(data && data.ok === true ? data : null);
          })
          .catch(() => {
            if (mounted.current) setInventory(null);
          })
          .finally(() => {
            if (mounted.current) setInventoryBusy(false);
          });
      }, []);

      // 实时拦截哨兵：拉取拦截事件 + 隔离区，处置（放行/删除）后自动刷新。
      const loadGuard = useCallback(() => {
        setGuardBusy(true);
        getJson('/api-checkup/guard')
          .then((data) => {
            if (!mounted.current) return;
            if (data && data.ok === true) {
              setGuardData(data);
              setGuardMessage(null);
            } else {
              setGuardMessage((data && data.error) || '哨兵数据读取失败');
            }
          })
          .catch((error) => {
            if (mounted.current) setGuardMessage(String(error));
          })
          .finally(() => {
            if (mounted.current) setGuardBusy(false);
          });
      }, []);

      useEffect(() => {
        loadGuard();
      }, [loadGuard]);

      const releaseGuardItem = useCallback(
        (dir, action) => {
          setGuardBusy(true);
          postJson('/api-checkup/guard/release', { dir, action })
            .then((data) => {
              if (!mounted.current) return;
              if (data && data.ok === true) setGuardMessage(action === 'delete' ? '已删除隔离条目' : '已放行回 skill 根');
              else setGuardMessage((data && data.error) || '操作失败');
            })
            .catch((error) => {
              if (mounted.current) setGuardMessage(String(error));
            })
            .finally(() => {
              if (mounted.current) loadGuard();
            });
        },
        [loadGuard],
      );

      const runArmoryScan = useCallback(() => {
        setArmoryBusy(true);
        setArmoryMessage(null);
        getJson('/api-checkup/armory')
          .then((data) => {
            if (!mounted.current) return;
            if (data && data.ok === true) setArmoryReport(data);
            else {
              setArmoryReport(null);
              setArmoryMessage((data && data.error) || '扫描失败');
            }
          })
          .catch((error) => {
            if (mounted.current) setArmoryMessage(String(error));
          })
          .finally(() => {
            if (mounted.current) setArmoryBusy(false);
          });
      }, []);

      const runAuditScan = useCallback(() => {
        setAuditBusy(true);
        setAuditMessage(null);
        getJson('/api-checkup/audit')
          .then((data) => {
            if (!mounted.current) return;
            if (data && data.ok === true) setAuditReport(data.report);
            else {
              setAuditReport(null);
              setAuditMessage((data && data.error) || '体检失败');
            }
          })
          .catch((error) => {
            if (mounted.current) setAuditMessage(String(error));
          })
          .finally(() => {
            if (mounted.current) setAuditBusy(false);
          });
      }, []);

      if (loading) {
        return h('div', { style: { padding: 12, fontSize: 13, color: C.dim } }, '读取配置中…');
      }
      if (loadError || !draft) {
        return h(
          'div',
          { style: { padding: 12, fontSize: 13, color: C.block } },
          `读取配置失败：${loadError || '接口没有返回配置'}`,
        );
      }

      return h(
        'div',
        { style: { color: C.text, paddingBottom: 64 } },
        h('div', { style: { fontSize: 15, fontWeight: 700, marginBottom: 4 } }, 'DSH体检中心'),
        h(
          'div',
          { style: { fontSize: 12, color: C.dim, marginBottom: 14, lineHeight: 1.7 } },
          '在装插件 / skills / MCP 之前预检兼容性：不通过就拒绝安装并列出原因。下面每一项都对应插件里真实生效的配置。',
        ),

        // 1. 总览
        h(
          Card,
          { title: '总览', desc: '当前生效状态与环境（只读）。' },
          h(
            'div',
            { style: { display: 'flex', flexWrap: 'wrap', gap: 8 } },
            [
              ['安装拦截', draft.preflightEnabled ? '已开启' : '已关闭'],
              ['DSH 版本', env ? env.dshVersion + (env.dshVersionKnown ? '' : '（未探测到）') : '-'],
              ['Node', env ? env.nodeVersion : '-'],
              ['客户端包', env ? String(env.clientPackages) : '-'],
              ['bundles', env ? String(env.bundles) : '-'],
            ].map(([label, value]) =>
              h(
                'div',
                {
                  key: label,
                  style: {
                    padding: '8px 12px',
                    borderRadius: 8,
                    background: 'rgba(0,0,0,.16)',
                    border: `1px solid ${C.border}`,
                    fontSize: 12,
                  },
                },
                h('span', { style: { color: C.dim, marginRight: 6 } }, label),
                h('span', { style: { fontWeight: 600 } }, value),
              ),
            ),
          ),
        ),

        // 2. 拦截设置
        h(
          Card,
          {
            title: '拦截设置',
            desc: '控制"装之前拦不拦、拦多严"。对应宿主 installBundle 拦截器。',
          },
          h(
            Row,
            {
              label: '启用安装预检拦截',
              desc: '开启：不兼容的安装被直接拒绝；关闭：只记录检查结果，不阻断安装。',
            },
            h(Toggle, {
              checked: draft.preflightEnabled,
              onChange: (value) => patch({ preflightEnabled: value }),
            }),
          ),
          h(
            Row,
            {
              label: '提醒项也视为不通过',
              desc: '更严格模式：版本声明缺失、peer 偏差等"提醒级"问题也拒绝安装。默认关闭。',
            },
            h(Toggle, {
              checked: draft.blockOnWarn,
              onChange: (value) => patch({ blockOnWarn: value }),
            }),
          ),
        ),

        // 3. 检查规则（只读，按三类分组）
        h(
          Card,
          {
            title: '检查规则',
            desc: '预检实际执行的规则（只读），按兼容性 / 安全性 / 稳定性分组。标「阻止安装」的任何一条命中都会拦下安装。',
          },
          rules.length === 0
            ? h('div', { style: { fontSize: 12, color: C.dim } }, '（宿主未返回规则列表）')
            : h(
                'div',
                { style: { display: 'flex', flexDirection: 'column', gap: 14 } },
                CATEGORY_ORDER.map((key) => {
                  const groupIds = rules.filter((id) => categoryOf(id) === key);
                  if (groupIds.length === 0) return null;
                  const info = CATEGORY_INFO[key];
                  return h(
                    'div',
                    { key },
                    h(
                      'div',
                      {
                        style: {
                          display: 'flex',
                          alignItems: 'baseline',
                          gap: 8,
                          marginBottom: 8,
                          paddingBottom: 6,
                          borderBottom: `1px solid ${C.border}`,
                        },
                      },
                      h('span', { style: { fontSize: 13, fontWeight: 700, color: C.text } }, info.label),
                      h('span', { style: { fontSize: 11, color: C.dim, flex: 1, minWidth: 0 } }, info.desc),
                      h('span', { style: { fontSize: 11, color: C.dim, flex: 'none' } }, `${groupIds.length} 项`),
                    ),
                    h(
                      'div',
                      { style: { display: 'flex', flexDirection: 'column', gap: 6 } },
                      groupIds.map((id) => {
                        const row = RULE_INFO[id] || ['兼容性', id, ''];
                        // 规则自带的默认等级
                        const defaultBlocking = [
                          'runtime-version',
                          'client-inject',
                          'client-platform',
                          'bundle-declared',
                          'known-bad',
                          'sec-scripts',
                          'sec-deps',
                          'sec-source',
                          'st-entrypoints',
                        ].includes(id);
                        // 用户在「处理方式」里选的值优先；未选则用默认
                        const customLevel = (draft.levelOverrides || {})[id];
                        const effective = customLevel || (defaultBlocking ? 'block' : 'warn');
                        const blocking = effective === 'block';
                        const levelLabel =
                          effective === 'block' ? '阻止' : effective === 'warn' ? '提醒' : '通过';
                        const levelColor =
                          effective === 'block' ? C.block : effective === 'warn' ? C.warn : C.pass;
                        const levelBorder =
                          effective === 'block'
                            ? 'rgba(255,107,107,.45)'
                            : effective === 'warn'
                              ? 'rgba(240,180,41,.45)'
                              : 'rgba(62,207,142,.45)';
                        return h(
                          'div',
                          {
                            key: id,
                            style: {
                              display: 'flex',
                              gap: 10,
                              alignItems: 'baseline',
                              padding: '7px 10px',
                              borderRadius: 7,
                              background: 'rgba(0,0,0,.14)',
                              border: `1px solid ${C.border}`,
                              fontSize: 12,
                            },
                          },
                          h(
                            'span',
                            {
                              style: {
                                flex: 'none',
                                fontSize: 11,
                                padding: '1px 7px',
                                borderRadius: 10,
                                color: levelColor,
                                border: `1px solid ${levelBorder}`,
                              },
                            },
                            levelLabel,
                          ),
                          customLevel
                            ? h(
                                'span',
                                {
                                  title: '已按你的设置覆盖规则默认等级',
                                  style: {
                                    flex: 'none',
                                    fontSize: 10,
                                    padding: '0 5px',
                                    borderRadius: 8,
                                    color: C.dim,
                                    border: `1px dashed ${C.border}`,
                                  },
                                },
                                '自定义',
                              )
                            : null,
                          h('span', { style: { fontWeight: 600, flex: 'none' } }, row[1]),
                          h('span', { style: { color: C.dim, minWidth: 0, flex: 1 } }, row[2]),
                          h(
                            'select',
                            {
                              value: customLevel || 'default',
                              title: '这条检查该怎么处理',
                              onChange: (event) => {
                                const next = { ...(draft.levelOverrides || {}) };
                                const value = event.target.value;
                                if (value === 'default') delete next[id];
                                else next[id] = value;
                                patch({ levelOverrides: next });
                              },
                              style: {
                                flex: 'none',
                                fontSize: 11,
                                padding: '3px 6px',
                                borderRadius: 6,
                                border: `1px solid ${C.border}`,
                                background: 'rgba(0,0,0,.18)',
                                color: C.text,
                              },
                            },
                            [
                              h('option', { key: 'default', value: 'default' }, '默认'),
                              h('option', { key: 'block', value: 'block' }, '阻止'),
                              h('option', { key: 'warn', value: 'warn' }, '提醒'),
                              h('option', { key: 'pass', value: 'pass' }, '通过'),
                            ],
                          ),
                        );
                      }),
                    ),
                  );
                }),
              ),
        ),

        // 4. 包源与读取
        h(
          Card,
          {
            title: '包源与读取',
            desc: '预检读取 package.json 的来源与网络容错参数。本机网络会间歇性超时，多源 + 重试是必要的。',
          },
          h(
            Row,
            { label: '注册表镜像', desc: '按顺序尝试，前面的失败会落到下一个。' },
            h('div', { style: { width: 320 } },
              h(ListEditor, {
                items: draft.registries,
                onChange: (items) => patch({ registries: items }),
                placeholder: 'https://registry.npmmirror.com',
                hint: '仅接受 http(s) 地址，至少保留一个。',
              }),
            ),
          ),
          h(
            Row,
            { label: '单次读取超时', desc: '1000–60000 ms。网络抖动时调大可减少跳过。' },
            h(
              'div',
              { style: { display: 'flex', alignItems: 'center', gap: 6 } },
              h(TextInput, {
                type: 'number',
                value: String(draft.lookupTimeoutMs),
                width: 100,
                onChange: (value) => patch({ lookupTimeoutMs: Number(value) || 0 }),
              }),
              h('span', { style: { fontSize: 12, color: C.dim } }, 'ms'),
            ),
          ),
          h(
            Row,
            { label: '每个源的尝试次数', desc: '1–5 次。' },
            h(TextInput, {
              type: 'number',
              value: String(draft.lookupAttempts),
              width: 80,
              onChange: (value) => patch({ lookupAttempts: Number(value) || 0 }),
            }),
          ),
        ),

        // 5. 黑名单
        h(
          Card,
          {
            title: '崩溃黑名单',
            desc: '已知会让桌面端起不来的包。命中即阻止安装；支持「包名」或「包名@版本」。',
          },
          h(ListEditor, {
            items: draft.knownBad,
            onChange: (items) => patch({ knownBad: items }),
            placeholder: 'dsh-broken-plugin@0.1.2',
            hint: '只写包名时对该包所有版本生效。',
          }),
        ),

        // 5b. 安全性：恶意依赖名单
        h(
          Card,
          {
            title: '恶意依赖名单（安全性）',
            desc: '被判定为恶意 / 病毒依赖的包名。候选包的依赖命中任何一条，就直接阻止安装。',
          },
          h(ListEditor, {
            items: draft.maliciousPackages || [],
            onChange: (items) => patch({ maliciousPackages: items }),
            placeholder: '@bad-scope/evil-pkg',
            hint: '支持包名与 scope（写 @scope 时该命名空间下全部都算命中）。',
          }),
        ),

        // 5c. Skill / MCP 检查（这两类没有安装 API）
        h(
          Card,
          {
            title: 'Skill / MCP 检查',
            desc: 'skill 是目录、MCP 是 profile 配置，宿主都没有"安装 API"可拦截，因此在这里提供装前检查与已装项体检。',
          },

          // Skill
          h('div', { style: { fontSize: 13, fontWeight: 600, marginBottom: 6 } }, 'Skill（检查目录）'),
          h(
            'div',
            { style: { display: 'flex', gap: 8, marginBottom: 8 } },
            h(TextInput, {
              value: skillPath,
              onChange: setSkillPath,
              width: 420,
              placeholder: '~/.dsh/skills/<name> 或任意 skill 目录',
            }),
            h(SmallButton, { tone: 'primary', onClick: runSkillCheck, disabled: skillBusy || !skillPath.trim() },
              skillBusy ? '检查中…' : '检查 skill',
            ),
          ),
          skillMessage
            ? h('div', { style: { fontSize: 12, color: C.warn, marginBottom: 8 } }, skillMessage)
            : null,
          skillReport ? h(CheckList, { checks: skillReport.checks }) : null,

          // MCP
          h(
            'div',
            { style: { fontSize: 13, fontWeight: 600, margin: '16px 0 6px' } },
            'MCP（检查配置）',
          ),
          h(
            'div',
            {
              style: {
                display: 'grid',
                // 第一列固定标签宽，第二列 minmax(0, 1fr) —— 0 最小宽是关键，
                // 默认的 auto 会让长 placeholder / select 撑破容器。
                gridTemplateColumns: 'minmax(92px, 120px) minmax(0, 1fr)',
                gap: '8px 10px',
                alignItems: 'center',
                maxWidth: '100%',
              },
            },
            h('span', { style: { fontSize: 12, color: C.dim, minWidth: 0 } }, 'transport'),
            h(
              'select',
              {
                value: mcpForm.transport,
                onChange: (event) => setMcpForm({ ...mcpForm, transport: event.target.value }),
                style: {
                  width: '100%',
                  maxWidth: '100%',
                  minWidth: 0,
                  boxSizing: 'border-box',
                  padding: '7px 10px',
                  borderRadius: 7,
                  border: `1px solid ${C.border}`,
                  background: 'rgba(0,0,0,.18)',
                  color: C.text,
                  fontSize: 12,
                },
              },
              ['stdio', 'sse', 'streamable-http'].map((value) => h('option', { key: value, value }, value)),
            ),
            h('span', { style: { fontSize: 12, color: C.dim, minWidth: 0 } }, 'serverName'),
            h(TextInput, {
              value: mcpForm.serverName,
              onChange: (value) => setMcpForm({ ...mcpForm, serverName: value }),
              width: '100%',
              placeholder: 'cad（工具前缀 mcp__cad__*）',
            }),
            h('span', { style: { fontSize: 12, color: C.dim, minWidth: 0 } }, 'command'),
            h(TextInput, {
              value: mcpForm.command,
              onChange: (value) => setMcpForm({ ...mcpForm, command: value }),
              width: '100%',
              placeholder: 'uvx / npx / 绝对路径',
            }),
            h('span', { style: { fontSize: 12, color: C.dim, minWidth: 0 } }, 'args'),
            h(TextInput, {
              value: mcpForm.args,
              onChange: (value) => setMcpForm({ ...mcpForm, args: value }),
              width: '100%',
              placeholder: '--from cadgen==0.7.26 cadgen mcp',
            }),
          ),
          h(
            'div',
            { style: { display: 'flex', gap: 8, marginTop: 10 } },
            h(SmallButton, { tone: 'primary', onClick: runMcpCheck, disabled: mcpBusy }, mcpBusy ? '检查中…' : '检查 MCP'),
            h(SmallButton, { onClick: runInventory, disabled: inventoryBusy }, inventoryBusy ? '体检中…' : '体检已装 skill / MCP'),
          ),
          mcpMessage ? h('div', { style: { fontSize: 12, color: C.warn, marginTop: 8 } }, mcpMessage) : null,
          mcpReport ? h(CheckList, { checks: mcpReport.checks }) : null,

          // 体检结果
          inventory
            ? h(
                'div',
                { style: { marginTop: 14 } },
                h(
                  'div',
                  { style: { fontSize: 12, color: C.dim, marginBottom: 6 } },
                  `已装 skill：${(inventory.skills || []).length} 个 · 已配 MCP：${(inventory.mcp || []).length} 个`,
                ),
                (inventory.skills || []).map((item) =>
                  h(
                    'div',
                    { key: `skill-${item.name}`, style: { fontSize: 12, padding: '4px 0', color: item.ok ? C.pass : C.block } },
                    `skill ${item.name}：${item.ok ? '通过' : `${item.blocked} 项阻止 / ${item.warned} 项提醒`}`,
                  ),
                ),
                (inventory.mcp || []).map((item) =>
                  h(
                    'div',
                    { key: `mcp-${item.id}`, style: { fontSize: 12, padding: '4px 0', color: item.ok ? C.pass : C.block } },
                    `mcp ${item.id}（${item.config.serverName || '未命名'}）：${item.ok ? '通过' : `${item.blocked} 项阻止 / ${item.warned} 项提醒`}`,
                  ),
                ),
              )
            : null,
        ),

        // 5c+. 实时拦截哨兵：skill/MCP 安装不走 installBundle，这里 watch 文件系统兜底。
        h(
          Card,
          {
            title: '实时拦截哨兵（skill / MCP 落盘监控）',
            desc: '军械库装 skill 是直接写 skills 目录、装 MCP 是直接写 profile patch，插件拦截器够不到。哨兵监听文件系统：新 skill / 新 MCP 条目落盘后数秒内自动检查，恶意脚本 skill 移入隔离区（可放行/删除），结构性问题的 MCP 条目自动摘除（带备份与 YAML 校验）。',
          },
          h(
            'div',
            { style: { display: 'flex', gap: 8, alignItems: 'center', marginBottom: 10 } },
            h(SmallButton, { tone: 'primary', onClick: loadGuard, disabled: guardBusy }, guardBusy ? '刷新中…' : '刷新拦截记录'),
            guardData
              ? h(
                  'span',
                  { style: { fontSize: 12, color: C.dim } },
                  `隔离区 ${((guardData.quarantined || []).length)} 项 · 事件 ${((guardData.events || []).length)} 条 · 监听 ${((guardData.roots || []).length)} 个 skill 根 + profile patch`,
                )
              : null,
          ),
          guardMessage ? h('div', { style: { fontSize: 12, color: C.warn, marginBottom: 8 } }, guardMessage) : null,
          guardData && (guardData.quarantined || []).length > 0
            ? h(
                'div',
                { style: { marginBottom: 10 } },
                h('div', { style: { fontSize: 13, fontWeight: 600, marginBottom: 6 } }, '隔离区（等待处置）'),
                (guardData.quarantined || []).map((dir) =>
                  h(
                    'div',
                    { key: dir, style: { display: 'flex', gap: 8, alignItems: 'center', padding: '4px 0' } },
                    h('span', { style: { fontSize: 12, flex: 1, color: C.block } }, dir),
                    h(SmallButton, { tone: 'primary', onClick: () => releaseGuardItem(dir, 'restore'), disabled: guardBusy }, '放行'),
                    h(SmallButton, { onClick: () => releaseGuardItem(dir, 'delete'), disabled: guardBusy }, '删除'),
                  ),
                ),
              )
            : null,
          guardData && (guardData.events || []).length > 0
            ? h(
                'div',
                null,
                h('div', { style: { fontSize: 13, fontWeight: 600, marginBottom: 6 } }, '最近拦截事件'),
                (guardData.events || []).slice(0, 12).map((event) =>
                  h(
                    'div',
                    { key: event.id, style: { fontSize: 12, padding: '3px 0', color: event.action === 'passed' ? C.pass : C.block } },
                    `[${String(event.at || '').replace('T', ' ').slice(0, 19)}] ${event.kind === 'mcp' ? `MCP ${event.mcpId}` : `skill ${event.name}`}：${sentinelActionLabel(event)}`,
                  ),
                ),
              )
            : null,
          guardData && (guardData.events || []).length === 0 && (guardData.quarantined || []).length === 0
            ? h('div', { style: { fontSize: 12, color: C.pass } }, '哨兵在线，暂无拦截事件（启动后新落盘的 skill / MCP 都会自动过检）。')
            : null,
        ),

        // 5e. 军械库四类检查：连接器 / 技能 / 插件 / 专家
        h(
          Card,
          {
            title: '军械库四类检查',
            desc: '覆盖大肥鱼军械库里的四类对象：连接器（MCP 条目）、技能（skills 目录，含专家捆绑技能）、插件（profile bundles）、专家（dsh-agent-preset 行）。',
          },
          h(
            'div',
            { style: { display: 'flex', gap: 8, alignItems: 'center', marginBottom: 10, flexWrap: 'wrap' } },
            h(SmallButton, { tone: 'primary', onClick: runArmoryScan, disabled: armoryBusy },
              armoryBusy ? '扫描中…' : '扫描四类对象',
            ),
            armoryReport
              ? h(
                  'span',
                  { style: { fontSize: 12, color: C.dim } },
                  `连接器 ${armoryReport.counts.connector} · 技能 ${armoryReport.counts.skill} · 插件 ${armoryReport.counts.plugin} · 专家 ${armoryReport.counts.expert}`,
                )
              : null,
          ),
          armoryMessage ? h('div', { style: { fontSize: 12, color: C.warn, marginBottom: 8 } }, armoryMessage) : null,
          armoryReport
            ? h(
                'div',
                { style: { display: 'flex', flexDirection: 'column', gap: 14 } },
                armoryReport.kinds.map((kind) => {
                  const rows = (armoryReport.checks || []).filter((check) => check.armoryKind === kind.id);
                  if (rows.length === 0) return null;
                  const stats = armoryReport.byKind[kind.id] || { total: rows.length };
                  return h(
                    'div',
                    { key: kind.id },
                    h(
                      'div',
                      {
                        style: {
                          display: 'flex',
                          alignItems: 'baseline',
                          gap: 8,
                          marginBottom: 8,
                          paddingBottom: 6,
                          borderBottom: `1px solid ${C.border}`,
                        },
                      },
                      h('span', { style: { fontSize: 13, fontWeight: 700 } }, kind.label),
                      h('span', { style: { fontSize: 11, color: C.dim, flex: 1, minWidth: 0 } }, kind.desc),
                      h(
                        'span',
                        { style: { fontSize: 11, color: C.dim, flex: 'none' } },
                        `${stats.total || rows.length} 项 · 阻止 ${stats.blocked ?? 0} · 提醒 ${stats.warned ?? 0}`,
                      ),
                    ),
                    h(CheckRows, { checks: rows }),
                  );
                }),
              )
            : null,
        ),

        // 5d. 环境体检：已装插件 / skill / MCP 的保留或卸载建议
        h(
          Card,
          {
            title: '环境体检（保留 / 卸载建议）',
            desc: '扫描已安装的插件、skill、MCP，逐项判断是否仍有必要保留：失效、重复、冲突、不兼容的给出卸载建议。',
          },
          h(
            'div',
            { style: { display: 'flex', gap: 8, alignItems: 'center', marginBottom: 10 } },
            h(SmallButton, { tone: 'primary', onClick: runAuditScan, disabled: auditBusy },
              auditBusy ? '扫描中…' : '扫描已装插件 / skill / MCP',
            ),
            auditReport
              ? h(
                  'span',
                  { style: { fontSize: 12, color: C.dim } },
                  `共 ${auditReport.summary.total} 项 · 保留 ${auditReport.summary.keep} · 建议卸载 ${auditReport.summary.remove} · 待确认 ${auditReport.summary.review}`,
                )
              : null,
          ),
          auditMessage ? h('div', { style: { fontSize: 12, color: C.warn, marginBottom: 8 } }, auditMessage) : null,
          auditReport
            ? h(
                'div',
                { style: { display: 'flex', flexDirection: 'column', gap: 14 } },
                [
                  ['plugin', '插件'],
                  ['skill', 'Skill'],
                  ['mcp', 'MCP'],
                ].map(([kind, label]) => {
                  const rows = auditReport.items.filter((row) => row.kind === kind);
                  if (rows.length === 0) return null;
                  const stats = auditReport.byKind[kind] || { total: rows.length };
                  return h(
                    'div',
                    { key: kind },
                    h(
                      'div',
                      {
                        style: {
                          display: 'flex',
                          alignItems: 'baseline',
                          gap: 8,
                          marginBottom: 8,
                          paddingBottom: 6,
                          borderBottom: `1px solid ${C.border}`,
                        },
                      },
                      h('span', { style: { fontSize: 13, fontWeight: 700 } }, label),
                      h(
                        'span',
                        { style: { fontSize: 11, color: C.dim, flex: 1, minWidth: 0 } },
                        `${stats.total || rows.length} 项 · 保留 ${stats.keep ?? '-'} · 卸载建议 ${stats.remove ?? '-'}`,
                      ),
                    ),
                    rows.map((row) => {
                      const tone =
                        row.verdict === 'remove' ? C.block : row.verdict === 'review' ? C.warn : C.pass;
                      const badge =
                        row.verdict === 'remove' ? '建议卸载' : row.verdict === 'review' ? '待确认' : '保留';
                      return h(
                        'div',
                        {
                          key: `${kind}-${row.name}-${row.path || ''}`,
                          style: {
                            padding: '8px 10px',
                            borderRadius: 7,
                            marginBottom: 6,
                            background: 'rgba(0,0,0,.14)',
                            border: `1px solid ${C.border}`,
                          },
                        },
                        h(
                          'div',
                          { style: { display: 'flex', alignItems: 'baseline', gap: 8 } },
                          h(
                            'span',
                            {
                              style: {
                                fontSize: 11,
                                fontWeight: 600,
                                flex: 'none',
                                padding: '1px 7px',
                                borderRadius: 10,
                                color: tone,
                                border: `1px solid ${tone}`,
                              },
                            },
                            badge,
                          ),
                          h(
                            'span',
                            { style: { fontSize: 12, fontWeight: 600, color: C.text } },
                            row.name + (row.version ? `@${row.version}` : ''),
                          ),
                          h('span', { style: { fontSize: 11, color: C.dim, flex: 1, minWidth: 0 } }, row.status),
                        ),
                        h(
                          'div',
                          { style: { fontSize: 12, color: C.dim, marginTop: 3, lineHeight: 1.6 } },
                          row.reason,
                        ),
                      );
                    }),
                  );
                }),
              )
            : null,
        ),

        // 6. 安装插件（主流程：检查 → 结果 → 开始安装）
        h(
          Card,
          {
            title: '安装插件',
            desc: '输入要安装的包，先跑检查并看结果；只有全部通过才会出现「开始安装插件」按钮。',
          },
          h(
            'div',
            { style: { display: 'flex', gap: 8, marginBottom: 12 } },
            h(TextInput, {
              value: installSpec,
              onChange: (value) => {
                setInstallSpec(value);
                setInstallStage('idle');
                setInstallReport(null);
                setInstallMessage(null);
              },
              width: 380,
              placeholder: 'dsh-xxx@1.2.3 或本地路径',
            }),
            h(
              SmallButton,
              {
                tone: 'primary',
                onClick: runInstallCheck,
                disabled: installStage === 'checking' || installStage === 'installing' || !installSpec.trim(),
              },
              installStage === 'checking' ? '检查中…' : '开始检查',
            ),
          ),

          // 步骤指示
          h(
            'div',
            { style: { display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: C.dim, marginBottom: 12 } },
            ...[
              ['1', '检查', ['checking', 'checked', 'installing', 'done'].includes(installStage)],
              ['2', '检查结果', ['checked', 'installing', 'done'].includes(installStage)],
              ['3', '开始安装插件', ['installing', 'done'].includes(installStage)],
            ].flatMap(([num, label, active], index) => [
              index > 0
                ? h('span', { key: `arrow-${num}`, style: { color: C.dim } }, '→')
                : null,
              h(
                'span',
                {
                  key: `step-${num}`,
                  style: {
                    padding: '2px 8px',
                    borderRadius: 10,
                    border: `1px solid ${active ? 'rgba(76,141,255,.6)' : C.border}`,
                    color: active ? C.accent : C.dim,
                    fontWeight: active ? 700 : 400,
                  },
                },
                `${num} ${label}`,
              ),
            ]),
          ),

          // 未通过：红色横幅 + 原因（不出现安装按钮）
          installReport && installReport.ok === false
            ? h(
                'div',
                {
                  style: {
                    padding: '12px 14px',
                    borderRadius: 10,
                    marginBottom: 10,
                    border: '1px solid rgba(255,107,107,.55)',
                    background: 'rgba(255,107,107,.1)',
                  },
                },
                h('div', { style: { fontSize: 14, fontWeight: 700, color: C.block } }, `检查未通过 · ${installReport.blocked} 项阻止安装`),
                h(
                  'div',
                  { style: { fontSize: 12, color: C.dim, marginTop: 4, lineHeight: 1.7 } },
                  '按下面列出的原因处理好后，再点「开始检查」；检查通过前不会执行安装。',
                ),
              )
            : null,

          // 通过：✅ 检查通过 + 安装按钮
          installReport && installReport.ok === true
            ? h(
                'div',
                {
                  style: {
                    padding: '12px 14px',
                    borderRadius: 10,
                    marginBottom: 10,
                    border: '1px solid rgba(62,207,142,.55)',
                    background: 'rgba(62,207,142,.1)',
                  },
                },
                h(
                  'div',
                  { style: { fontSize: 14, fontWeight: 700, color: C.pass, display: 'flex', alignItems: 'center', gap: 8 } },
                  h('span', { style: { fontSize: 16 } }, '✅'),
                  '检查通过',
                ),
                h(
                  'div',
                  { style: { fontSize: 12, color: C.dim, marginTop: 4, lineHeight: 1.7 } },
                  `${installReport.passed} 项检查全部通过${installReport.warned ? `，${installReport.warned} 条提醒不影响安装` : ''}。确认无误后可以开始安装。`,
                ),
                installStage === 'done'
                  ? null
                  : h(
                      'div',
                      { style: { marginTop: 10, display: 'flex', alignItems: 'center', gap: 10 } },
                      h(
                        SmallButton,
                        {
                          tone: 'primary',
                          onClick: runInstall,
                          disabled: installStage === 'installing',
                        },
                        installStage === 'installing' ? '安装中…' : '开始安装插件',
                      ),
                      h('span', { style: { fontSize: 12, color: C.dim } }, '安装由宿主执行，完成后需重启桌面端生效'),
                    ),
              )
            : null,

          // 安装结果 / 错误提示
          installMessage
            ? h(
                'div',
                {
                  style: {
                    padding: '9px 12px',
                    borderRadius: 8,
                    marginBottom: 10,
                    fontSize: 12,
                    lineHeight: 1.7,
                    border: `1px solid ${installStage === 'done' ? 'rgba(62,207,142,.45)' : 'rgba(240,180,41,.45)'}`,
                    background: installStage === 'done' ? 'rgba(62,207,142,.08)' : 'rgba(240,180,41,.08)',
                    color: installStage === 'done' ? C.pass : C.warn,
                  },
                },
                installMessage,
              )
            : null,

          installReport ? h(CheckList, { checks: installReport.checks }) : null,
        ),

        // 7. 手动预检
        h(
          Card,
          {
            title: '手动预检',
            desc: '不改动环境，只跑一次检查。用于装之前先看结论。',
          },
          h(
            'div',
            { style: { display: 'flex', gap: 8, marginBottom: 10 } },
            h(TextInput, {
              value: spec,
              onChange: setSpec,
              width: 360,
              placeholder: 'dsh-xxx@1.2.3 或本地路径',
            }),
            h(SmallButton, { tone: 'primary', onClick: runCheck, disabled: checking || !spec.trim() },
              checking ? '检查中…' : '开始预检',
            ),
          ),
          report
            ? h(
                'div',
                {
                  style: {
                    padding: '10px 12px',
                    borderRadius: 8,
                    marginBottom: 10,
                    border: `1px solid ${report.ok ? 'rgba(62,207,142,.45)' : 'rgba(255,107,107,.5)'}`,
                    background: report.ok ? 'rgba(62,207,142,.08)' : 'rgba(255,107,107,.1)',
                  },
                },
                h(
                  'div',
                  { style: { fontSize: 13, fontWeight: 700, color: report.ok ? C.pass : C.block } },
                  report.ok
                    ? report.preflightEnabled === false
                      ? '检查通过（注意：当前拦截已关闭，不会生效）'
                      : '预检通过，可以放心安装'
                    : `预检未通过：${report.blocked} 项会阻止安装`,
                ),
                h(
                  'div',
                  { style: { fontSize: 12, color: C.dim, marginTop: 3 } },
                  `${report.passed || 0} 项通过 · ${report.warned || 0} 项提醒 · ${report.spec || ''}`,
                ),
              )
            : null,
          report && report.checks ? h(CheckList, { checks: report.checks }) : null,
        ),

        // 7. 最近记录
        h(
          Card,
          { title: '最近记录', desc: '预检历史（每次安装拦截与手动预检都会留下一条，最多 50 条）。' },
          history.length === 0
            ? h('div', { style: { fontSize: 12, color: C.dim } }, '暂无记录')
            : h(
                'div',
                { style: { display: 'flex', flexDirection: 'column', gap: 6 } },
                history.slice(0, 10).map((entry, index) =>
                  h(
                    'div',
                    {
                      key: `${entry.at}-${index}`,
                      style: {
                        display: 'flex',
                        alignItems: 'center',
                        gap: 8,
                        padding: '7px 10px',
                        borderRadius: 7,
                        background: 'rgba(0,0,0,.14)',
                        border: `1px solid ${C.border}`,
                        fontSize: 12,
                      },
                    },
                    h(LevelDot, { level: entry.ok ? 'pass' : 'block' }),
                    h(
                      'span',
                      { style: { flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } },
                      entry.spec,
                    ),
                    h('span', { style: { color: C.dim, flex: 'none' } }, entry.ok ? '通过' : `拦截 ${entry.blocked} 项`),
                    h('span', { style: { color: C.dim, flex: 'none' } }, new Date(entry.at).toLocaleString()),
                  ),
                ),
              ),
        ),

        // 底部保存条：只在「有未保存修改 / 保存中 / 保存结果」时出现；
        // 保存成功 2 秒后自动收起，放弃修改立即收起。
        dirty || saving || Boolean(saveResult)
          ? h(
              'div',
              {
                style: {
                  position: 'sticky',
                  bottom: 0,
                  display: 'flex',
                  alignItems: 'center',
                  gap: 10,
                  padding: '10px 12px',
                  marginTop: 4,
                  borderRadius: 10,
                  background: 'rgba(20,20,24,.92)',
                  border: `1px solid ${C.border}`,
                },
              },
              h(
                'span',
                { style: { fontSize: 12, color: dirty ? C.warn : C.dim, flex: 1, minWidth: 0 } },
                saveResult
                  ? saveResult.message
                  : saving
                    ? '保存中…'
                    : '有未保存的修改',
              ),
              h(SmallButton, { onClick: reset, disabled: !dirty || saving }, '放弃修改'),
              h(SmallButton, { tone: 'primary', onClick: save, disabled: !dirty || saving }, saving ? '保存中…' : '保存'),
            )
          : null,
      );
    }

    // ── 全局检查浮层（市场点「安装」后自动弹出）────────────────────────────
    //
    // 挂到 document.body，不渲染在 shell.overlay 槽里：槽的祖先可能带 transform /
    // filter / contain，会形成新的 stacking context，把 position:fixed 与 z-index
    // 困在容器内——实测会被 DSH 自己的「正在准备安装…」对话框盖住。
    const OVERLAY_ID = 'checkup-overlay-root';
    const overlayState = { pending: null, message: null, busy: false };

    function ensureOverlayHost() {
      let host = document.getElementById(OVERLAY_ID);
      if (host && host.isConnected) return host;
      host = document.createElement('div');
      host.id = OVERLAY_ID;
      host.style.cssText = [
        'position:fixed',
        'inset:0',
        'z-index:2147483000',
        'display:none',
        'align-items:center',
        'justify-content:center',
        'background:rgba(0,0,0,.55)',
      ].join(';');
      document.body.appendChild(host);
      return host;
    }

    function escHtml(value) {
      return String(value == null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }

    function overlayBtn(label, action, opts) {
      const primary = opts && opts.primary;
      const disabled = opts && opts.disabled;
      return (
        `<button data-action="${action}"${disabled ? ' disabled' : ''} style="` +
        'padding:7px 14px;border-radius:7px;font-size:12px;font-weight:600;cursor:' +
        (disabled ? 'default' : 'pointer') +
        ';opacity:' +
        (disabled ? '.5' : '1') +
        ';border:1px solid rgba(255,255,255,.14);' +
        (primary ? 'background:#4c8dff;color:#fff;' : 'background:rgba(255,255,255,.08);color:#e8e8ea;') +
        `">${escHtml(label)}</button>`
      );
    }

    function overlayRowsOfCategory(rows) {
      const order = { block: 0, warn: 1, pass: 2 };
      return rows
        .slice()
        .sort((a, b) => (order[a.level] ?? 9) - (order[b.level] ?? 9))
        .map((check) => {
          const color = check.level === 'block' ? '#ff6b6b' : check.level === 'warn' ? '#f0b429' : '#3ecf8e';
          const label = check.level === 'block' ? '阻止安装' : check.level === 'warn' ? '仅提醒' : '通过';
          const detail = check.detail
            ? `<div style="font-size:12px;color:#9a9aa2;margin-top:3px;line-height:1.6;">${escHtml(check.detail)}</div>`
            : '';
          const hint = check.hint
            ? `<div style="font-size:12px;color:#3ecf8e;margin-top:3px;line-height:1.6;">建议：${escHtml(check.hint)}</div>`
            : '';
          return (
            '<div style="display:flex;gap:8px;padding:9px 11px;border-radius:8px;background:rgba(0,0,0,.18);' +
            'border:1px solid rgba(255,255,255,.12);margin-bottom:8px;">' +
            `<span style="width:8px;height:8px;border-radius:4px;background:${color};margin-top:5px;flex:none;"></span>` +
            '<div style="min-width:0;">' +
            `<div style="font-size:12px;font-weight:700;color:#e8e8ea;">${escHtml(check.title)} · ${label}</div>` +
            detail +
            hint +
            '</div></div>'
          );
        })
        .join('');
    }

    /// 浮层里按「兼容性 / 安全性 / 稳定性」分组展示。
    function overlayCheckRows(checks) {
      const groups = groupChecks(Array.isArray(checks) ? checks : []);
      return CATEGORY_ORDER.filter((key) => groups[key].length > 0)
        .map((key) => {
          const rows = groups[key];
          const stats = categoryStats(rows);
          const info = CATEGORY_INFO[key];
          const tone = stats.blocked > 0 ? '#ff6b6b' : stats.warned > 0 ? '#f0b429' : '#3ecf8e';
          const badge =
            stats.blocked > 0
              ? `${stats.blocked} 项阻止`
              : stats.warned > 0
                ? `${stats.warned} 项提醒`
                : `${stats.total} 项通过`;
          return (
            '<div style="margin-bottom:14px;">' +
            '<div style="display:flex;align-items:baseline;gap:8px;margin-bottom:8px;padding-bottom:6px;' +
            'border-bottom:1px solid rgba(255,255,255,.12);">' +
            `<span style="font-size:13px;font-weight:700;color:#e8e8ea;">${escHtml(info.label)}</span>` +
            `<span style="font-size:11px;color:#9a9aa2;flex:1;min-width:0;">${escHtml(info.desc)}</span>` +
            `<span style="font-size:11px;color:${tone};font-weight:600;flex:none;">${badge}</span>` +
            '</div>' +
            overlayRowsOfCategory(rows) +
            '</div>'
          );
        })
        .join('');
    }

    function renderOverlay() {
      const host = ensureOverlayHost();
      const { pending, message, busy } = overlayState;
      if (!pending && !message) {
        host.style.display = 'none';
        host.innerHTML = '';
        return;
      }
      host.style.display = 'flex';

      const report = pending ? pending.report : null;
      const passed = Boolean(report && report.ok === true);

      let banner = '';
      if (message) {
        banner =
          `<div style="padding:10px 12px;border-radius:8px;font-size:12px;line-height:1.7;` +
          `border:1px solid ${message.ok ? 'rgba(62,207,142,.45)' : 'rgba(240,180,41,.45)'};` +
          `background:${message.ok ? 'rgba(62,207,142,.08)' : 'rgba(240,180,41,.08)'};` +
          `color:${message.ok ? '#3ecf8e' : '#f0b429'};">${escHtml(message.text)}</div>`;
      } else if (report && passed) {
        banner =
          '<div style="padding:12px 14px;border-radius:10px;margin-bottom:12px;' +
          'border:1px solid rgba(62,207,142,.55);background:rgba(62,207,142,.1);">' +
          '<div style="display:flex;align-items:center;gap:8px;font-size:15px;font-weight:700;color:#3ecf8e;">' +
          '<span style="font-size:17px;">✅</span>检查通过</div>' +
          `<div style="font-size:12px;color:#9a9aa2;margin-top:4px;line-height:1.7;">${report.passed} 项检查全部通过` +
          `${report.warned ? `，${report.warned} 条提醒不影响安装` : ''}。确认无误后点「开始安装插件」。</div></div>`;
      } else if (report) {
        // 未通过有两种：真有 block，或严格模式（blockOnWarn）把提醒也当成拦截。
        const strictOnly = !report.blocked || report.blocked === 0;
        banner =
          '<div style="padding:12px 14px;border-radius:10px;margin-bottom:12px;' +
          'border:1px solid rgba(255,107,107,.55);background:rgba(255,107,107,.1);">' +
          '<div style="display:flex;align-items:center;gap:8px;font-size:15px;font-weight:700;color:#ff6b6b;">' +
          `<span style="font-size:17px;">❌</span>${strictOnly
            ? `检查未通过 · 严格模式拦下 ${report.warned || 0} 项提醒`
            : `检查未通过 · ${report.blocked} 项阻止安装`}</div>` +
          '<div style="font-size:12px;color:#9a9aa2;margin-top:4px;line-height:1.7;">' +
          `安装已暂停，不会执行。${strictOnly
            ? '当前开启了「提醒级也拦截」（blockOnWarn），可在面板里关掉后重试。'
            : '按下面列出的原因处理后，重新点安装。'}</div></div>`;
      }

      const footer = message
        ? overlayBtn('关闭', 'dismiss')
        : (passed ? overlayBtn(busy ? '安装中…' : '开始安装插件', 'install', { primary: true, disabled: busy }) : '') +
          overlayBtn(passed ? '取消安装' : '关闭（不安装）', 'cancel', { disabled: busy });

      host.innerHTML =
        '<div style="width:720px;max-width:92vw;max-height:82vh;display:flex;flex-direction:column;' +
        'border-radius:14px;border:1px solid rgba(255,255,255,.12);background:rgba(24,24,28,.98);' +
        'box-shadow:0 24px 64px rgba(0,0,0,.55);color:#e8e8ea;">' +
        '<div style="display:flex;align-items:center;gap:10px;padding:14px 16px;border-bottom:1px solid rgba(255,255,255,.12);">' +
        '<span style="font-size:15px;font-weight:700;">DSH体检中心 · 安装前检查</span>' +
        '<span style="font-size:12px;color:#9a9aa2;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' +
        `${escHtml(pending ? pending.spec : '')}</span></div>` +
        `<div style="padding:14px 16px;overflow:auto;">${banner}${report ? overlayCheckRows(report.checks) : ''}</div>` +
        `<div style="display:flex;justify-content:flex-end;gap:10px;padding:12px 16px;border-top:1px solid rgba(255,255,255,.12);">${footer}</div>` +
        '</div>';
    }

    function GuardOverlay() {
      useEffect(() => {
        let disposed = false;
        let timer;
        const host = ensureOverlayHost();

        const onClick = (event) => {
          const el = event.target && event.target.closest ? event.target.closest('[data-action]') : null;
          if (!el) return;
          const action = el.getAttribute('data-action');
          if (action === 'dismiss') {
            overlayState.message = null;
            renderOverlay();
            return;
          }
          const pending = overlayState.pending;
          if (!pending) return;
          overlayState.busy = true;
          renderOverlay();
          postJson('/api-checkup/confirm', { id: pending.id, action })
            .then((data) => {
              if (disposed) return;
              if (data && data.ok === true) {
                overlayState.pending = null;
                overlayState.message =
                  action === 'install'
                    ? { ok: true, text: '已开始安装，完成后重启桌面端生效。' }
                    : { ok: false, text: '已取消本次安装。' };
              } else {
                overlayState.message = { ok: false, text: (data && data.error) || '操作失败' };
              }
            })
            .catch((error) => {
              overlayState.message = { ok: false, text: String(error) };
            })
            .finally(() => {
              overlayState.busy = false;
              if (!disposed) renderOverlay();
            });
        };

        host.addEventListener('click', onClick);

        const poll = () => {
          getJson('/api-checkup/pending')
            .then((data) => {
              if (disposed) return;
              if (data && data.ok === true && data.pending) {
                if (!overlayState.pending || overlayState.pending.id !== data.pending.id) {
                  overlayState.pending = data.pending;
                  overlayState.message = null;
                  overlayState.busy = false;
                  renderOverlay();
                }
              }
              timer = setTimeout(poll, 1500);
            })
            .catch(() => {
              timer = setTimeout(poll, 3000);
            });
        };
        poll();

        return () => {
          disposed = true;
          clearTimeout(timer);
          host.removeEventListener('click', onClick);
          const alive = document.getElementById(OVERLAY_ID);
          if (alive) {
            alive.style.display = 'none';
            alive.innerHTML = '';
          }
        };
      }, []);

      return null;
    }

    // ── 落盘检查提示（右下角轻提示）──────────────────────────────────────
    //
    // 军械库装 skill / MCP 不走 installBundle，落盘后由哨兵检查；检查通过时旧实现
    // 完全静默，用户以为"没检查"。这里把每条哨兵事件变成一条右下角提示：
    //   passed → 绿色（检查过了）、warned → 黄色、quarantined/removed → 红色。
    // 用原生 DOM 挂 body，避开槽容器的 stacking context。
    const TOAST_ID = 'checkup-sentinel-toast-root';
    const toastState = { items: [], seen: new Set(), timer: null, polling: null, host: null };

    function ensureToastHost() {
      let host = document.getElementById(TOAST_ID);
      if (host && host.isConnected) return host;
      host = document.createElement('div');
      host.id = TOAST_ID;
      host.style.cssText = [
        'position:fixed',
        'right:16px',
        'bottom:16px',
        'z-index:2147483000',
        'display:flex',
        'flex-direction:column',
        'gap:8px',
        'max-width:360px',
        'pointer-events:none',
      ].join(';');
      document.body.appendChild(host);
      return host;
    }

    function sentinelTone(action) {
      if (action === 'quarantined' || action === 'removed') return { color: '#ff6b6b', icon: '⛔', text: '已拦截' };
      if (action === 'warn-only') return { color: '#f0b429', icon: '⚠️', text: '有提醒' };
      return { color: '#3ecf8e', icon: '✅', text: '通过' };
    }

    function renderToasts() {
      const host = ensureToastHost();
      host.innerHTML = toastState.items
        .map((item) => {
          const tone = sentinelTone(item.action);
          const kindLabel = item.kind === 'mcp' ? '连接器' : '技能';
          return (
            '<div style="pointer-events:auto;display:flex;gap:8px;align-items:flex-start;' +
            'padding:9px 11px;border-radius:9px;background:rgba(20,20,24,.96);' +
            `border:1px solid ${tone.color}66;box-shadow:0 8px 24px rgba(0,0,0,.45);` +
            'font-size:12px;line-height:1.6;color:#e8e8ea;">' +
            `<span style="flex:none;">${tone.icon}</span>` +
            '<div style="min-width:0;">' +
            `<div><b>${escHtml(kindLabel)} ${escHtml(item.name)}</b> · ${tone.text}</div>` +
            `<div style="color:#9a9aa2;margin-top:2px;">${escHtml(item.detail)}</div>` +
            '</div></div>'
          );
        })
        .join('');
      if (toastState.items.length === 0) host.innerHTML = '';
    }

    function pushToast(event) {
      const tone = sentinelTone(event.action);
      const blocked = Array.isArray(event.blockedIds) ? event.blockedIds : [];
      const detail =
        event.action === 'quarantined'
          ? `命中 ${blocked.join(', ') || '阻止项'}，已移入隔离区`
          : event.action === 'removed'
            ? `命中 ${blocked.join(', ') || '阻止项'}，已从配置摘除`
            : event.action === 'warn-only'
              ? '有提醒项，未自动处理'
              : `未发现阻止/提醒项（${tone.text}）`;
      toastState.items.push({ ...event, detail });
      if (toastState.items.length > 3) toastState.items.shift();
      renderToasts();
      // 8 秒后自动消失；拦截类留 12 秒，给用户反应时间。
      const life = event.action === 'quarantined' || event.action === 'removed' ? 12000 : 8000;
      const target = toastState.items[toastState.items.length - 1];
      setTimeout(() => {
        toastState.items = toastState.items.filter((row) => row !== target);
        renderToasts();
      }, life);
    }

    function SentinelToast() {
      useEffect(() => {
        let disposed = false;
        ensureToastHost();

        const poll = () => {
          getJson('/api-checkup/guard')
            .then((data) => {
              if (disposed) return;
              const events = Array.isArray(data && data.events) ? data.events : [];
              // 事件是"最新在前"的，反序遍历才能按时间顺序弹出。
              for (const event of [...events].reverse()) {
                if (!event || typeof event.id !== 'string') continue;
                if (toastState.seen.has(event.id)) continue;
                toastState.seen.add(event.id);
                // #9 seen 只增不减会长期积累；超过上限时丢掉最早的一半。
                if (toastState.seen.size > 200) {
                  const stale = [...toastState.seen].slice(0, 100);
                  for (const id of stale) toastState.seen.delete(id);
                }
                pushToast(event);
              }
              toastState.polling = setTimeout(poll, 2500);
            })
            .catch(() => {
              toastState.polling = setTimeout(poll, 5000);
            });
        };
        poll();

        return () => {
          disposed = true;
          clearTimeout(toastState.polling);
          const host = document.getElementById(TOAST_ID);
          if (host) host.innerHTML = '';
        };
      }, []);

      return null;
    }

    // ── 插件详情页的预检区（市场里点进任何一个插件都能看到）─────────────────
    //
    // 宿主渲染方式是 renderSlot('plugins.detail.section', { subject })，
    // subject.pkg = { name, version }，槽类型是 list（不需要 key）。
    function DetailSection(props) {
      const subject = props && props.subject ? props.subject : null;
      const pkg = subject && subject.pkg ? subject.pkg : null;
      const name = pkg && typeof pkg.name === 'string' ? pkg.name : '';
      const version = pkg && typeof pkg.version === 'string' ? pkg.version : '';
      const [phase, setPhase] = useState('idle'); // idle | loading | done | error
      const [report, setReport] = useState(null);
      const [message, setMessage] = useState(null);
      const alive = useRef(true);

      const run = useCallback(() => {
        if (!name) return;
        const spec = version ? `${name}@${version}` : name;
        setPhase('loading');
        setMessage(null);
        postJson('/api-checkup/check', { spec })
          .then((data) => {
            if (!alive.current) return;
            if (data && data.ok === true && data.report) {
              setReport(data.report);
              setPhase('done');
            } else {
              setPhase('error');
              setMessage((data && data.error) || '预检失败');
            }
          })
          .catch((error) => {
            if (!alive.current) return;
            setPhase('error');
            setMessage(String(error));
          });
      }, [name, version]);

      useEffect(() => {
        alive.current = true;
        run();
        return () => {
          alive.current = false;
        };
      }, [run]);

      if (!name) return null;

      const passed = report && report.ok === true;

      return h(
        'section',
        {
          'data-checkup-detail': name,
          style: {
            border: `1px solid ${C.border}`,
            borderRadius: 10,
            background: C.card,
            padding: '14px 16px',
            marginTop: 12,
          },
        },
        h(
          'div',
          { style: { display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 } },
          h('span', { style: { fontSize: 13, fontWeight: 700, color: C.text } }, 'DSH体检中心 · 安装前预检'),
          h('span', { style: { fontSize: 11, color: C.dim, flex: 1, minWidth: 0 } }, name + (version ? `@${version}` : '')),
          phase === 'done' && report
            ? h(
                'span',
                {
                  style: {
                    fontSize: 11,
                    fontWeight: 600,
                    padding: '2px 8px',
                    borderRadius: 10,
                    color: passed ? C.pass : C.block,
                    border: `1px solid ${passed ? 'rgba(62,207,142,.45)' : 'rgba(255,107,107,.45)'}`,
                  },
                },
                // 未通过不一定是有 block：严格模式（blockOnWarn）下 warn 也会拦，文案要区分。
                passed
                  ? `✅ 通过 · ${report.passed} 项`
                  : report.blocked > 0
                    ? `❌ ${report.blocked} 项阻止`
                    : `⚠️ 严格模式拦截 · ${report.warned || 0} 项提醒`,
              )
            : null,
          h(
            SmallButton,
            { onClick: run, disabled: phase === 'loading' },
            phase === 'loading' ? '预检中…' : '重新预检',
          ),
        ),
        phase === 'loading'
          ? h('div', { style: { fontSize: 12, color: C.dim } }, '正在读取包元数据并逐项核对…')
          : null,
        phase === 'error' ? h('div', { style: { fontSize: 12, color: C.warn } }, message || '预检失败') : null,
        report ? h(CheckList, { checks: report.checks }) : null,
      );
    }

    // ── 设置导航图标补丁 ────────────────────────────────────────────────────
    //
    // 宿主 `settings.section` 只收 id/order/label，导航图标来自 shell 里
    // `navIcon(id)` 的硬编码映射，未知 section 一律给兜底齿轮 —— 想换只能改 DOM。
    // 这里替换 navCell 内 <svg> 的子路径（保留宿主给的 class，尺寸与颜色继续继承）。
    const NAV_ICON_PATHS = {
      // 护盾 + 对勾：体检中心（健康 / 防护语义）
      '体检中心': [
        'M8 1.8 13.2 3.6v4.2c0 3.2-2.2 5.3-5.2 6.3-3-1-5.2-3.1-5.2-6.3V3.6L8 1.8Z',
        'm5.9 8 1.4 1.4 2.8-2.9',
      ],
      // 地球：浏览器
      '浏览器': [
        'M14.2 8A6.2 6.2 0 1 1 1.8 8a6.2 6.2 0 0 1 12.4 0Z',
        'M1.8 8h12.4',
        'M8 1.8c1.7 1.8 2.5 4 2.5 6.2S9.7 12.4 8 14.2C6.3 12.4 5.5 10.2 5.5 8S6.3 3.6 8 1.8Z',
      ],
    };

    function paintNavIcon(svg, paths, mark) {
      if (!svg || !Array.isArray(paths) || paths.length === 0) return false;
      if (svg.getAttribute('data-ed-nav-icon') === mark) return false;
      svg.setAttribute('fill', 'none');
      svg.setAttribute('stroke', 'currentColor');
      svg.setAttribute('stroke-width', '1.3');
      svg.setAttribute('stroke-linecap', 'round');
      svg.setAttribute('stroke-linejoin', 'round');
      svg.innerHTML = paths.map((d) => `<path d="${d}"/>`).join('');
      svg.setAttribute('data-ed-nav-icon', mark);
      return true;
    }

    /// 给设置左侧导航的两个入口打上自定义图标；返回清理函数。
    function patchSettingsNavIcons() {
      if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') {
        return () => {};
      }
      let stopped = false;

      const replace = () => {
        if (stopped) return;
        let changed = 0;
        for (const button of document.querySelectorAll('button')) {
          const className = String(button.getAttribute('class') || '');
          if (!className.includes('navCell')) continue;
          const label = (button.textContent || '').trim();
          const paths = NAV_ICON_PATHS[label];
          if (!paths) continue;
          const svg = button.querySelector('svg');
          if (paintNavIcon(svg, paths, `ed:${label}`)) changed += 1;
        }
        return changed;
      };

      replace();
      // #6 节流：会话流式输出每秒触发几十次 DOM 变化，每次全量扫 button 太浪费。
      let scheduled = 0;
      const observer = new MutationObserver(() => {
        if (scheduled) return;
        scheduled = setTimeout(() => {
          scheduled = 0;
          replace();
        }, 200);
      });
      try {
        observer.observe(document.body, { childList: true, subtree: true });
      } catch {
        // body 尚未就绪：由下一次 apply/重开设置页时再试
      }
      return () => {
        stopped = true;
        if (scheduled) clearTimeout(scheduled);
        observer.disconnect();
      };
    }

    // ── 设置面板入口「DSH体检中心」─────────────────────────────────────────
    //
    // 注册到 settings.section 后，设置左侧导航会多一项「DSH体检中心」，
    // 点开就是完整体检中心（与插件详情页里的面板同一套组件）。
    function HealthCenterPage() {
      return h(GuardPanel);
    }

    function apply(ctx) {
      ctx.slots.inject('plugins.bundle.config', () =>
        ctx.slots.register(
          {
            name: 'plugins.bundle.config',
            key: 'dsh-checkup',
            label: () => 'DSH体检中心',
          },
          GuardPanel,
        ),
      );
      // 同一个面板再挂到 row.config：profile 里 bundle patch 的行（include:checkup）
      // 在插件页是按「行」渲染的，key 规则是 `${bundle}#${rowId}`。
      ctx.slots.inject('plugins.row.config', () =>
        ctx.slots.register(
          {
            name: 'plugins.row.config',
            key: 'dsh-checkup#checkup',
            label: () => 'DSH体检中心',
          },
          GuardPanel,
        ),
      );
      // 落盘检查提示：任何界面右下角弹一条，告知"刚装的东西检查过了"。
      ctx.slots.inject('shell.overlay', () =>
        ctx.slots.register(
          {
            name: 'shell.overlay',
            id: 'checkup-sentinel-toast',
            inject: () => ({}),
          },
          SentinelToast,
        ),
      );
      // 全局浮层：不依赖设置页，任何界面都能弹出。
      ctx.slots.inject('shell.overlay', () =>
        ctx.slots.register(
          {
            name: 'shell.overlay',
            id: 'checkup-confirm',
            inject: () => ({}),
          },
          GuardOverlay,
        ),
      );
      // 插件详情页（市场里点进任何插件）：list 型槽，注册必须带 id 与 order，否则被宿主静默丢弃。
      ctx.slots.inject('plugins.detail.section', () =>
        ctx.slots.register(
          {
            name: 'plugins.detail.section',
            id: 'dsh-checkup/preflight',
            order: 100,
            label: () => 'DSH体检中心预检',
          },
          DetailSection,
        ),
      );
      // 设置面板左侧导航新增「体检中心」入口：点开即体检中心整页。
      // 导航文字按用户指定只写「体检中心」，其余界面仍用「DSH体检中心」。
      ctx.slots.inject('settings.section', () =>
        ctx.slots.register(
          {
            name: 'settings.section',
            id: 'checkup-health',
            order: 510,
            label: () => '体检中心',
          },
          HealthCenterPage,
        ),
      );
      // 导航图标：宿主 navIcon(id) 是硬编码映射，未知 id 给兜底齿轮，只能 DOM 替换。
      ctx.effect(() => patchSettingsNavIcons());
    }

    module.exports = { name, inject, apply };
    return module.exports;
  },
});
