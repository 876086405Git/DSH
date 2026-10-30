// Install Guard — 专家（expert）候选检查
//
// 专家不是"包"：它是 profile/cordis.patch.yml 里一条 @deepseek-ai/dsh-agent-preset
// 配置行（id 以 preset-wbexpert- 开头，人设正文内嵌在 config.plugins[].config.prefix）。
// 宿主没有专家安装 API，写进去就是一条配置，所以这里做两件事：
//   1) 结构：这条候选写下去会不会是个空人设；
//   2) 交叉比对：与已装专家是否撞 id / 撞名 / 同一套人设换个名字，以及引用的插件是否装了。
//
// 与 armory.js 的分工：那边查「已装专家自己的结构和孤儿状态」（arm-expert-*），
// 这边查「候选专家 vs 已装专家」（cand-expert-*）。两套 id 不重叠，避免重复报告。

const ID_PREFIX = 'preset-wbexpert-';
const MIN_PERSONA_CHARS = 20;

const pass = (id, title, detail) => ({ id, category: 'compatibility', level: 'pass', title, detail });
const warn = (id, title, detail, hint, category = 'stability') => ({ id, category, level: 'warn', title, detail, hint });
const block = (id, title, detail, hint, category = 'compatibility') => ({ id, category, level: 'block', title, detail, hint });

const text = (value) => String(value == null ? '' : value).replace(/\s+/g, ' ').trim();

/// 人设正文的比对键：去掉所有空白与标点后再比，避免排版差异掩盖"同一套人设"。
export function personaKey(value) {
  return text(value)
    .replace(/[^\p{L}\p{N}]/gu, '')
    .toLowerCase();
}

/**
 * 检查一个候选专家。
 *
 * @param candidate - { id, name, persona, externalRefs? }
 * @param env.experts       已装专家 [{ id, name, persona, plugin, externalRefs }]
 * @param env.installedNames 已装包名（profile bundles + node_modules），用于引用检查
 * @param env.selfId         被检查对象自己的 id（体检已装项时排除自己，避免自报重复）
 */
export function checkExpert(candidate, env = {}) {
  const checks = [];
  const expert = candidate && typeof candidate === 'object' ? candidate : {};
  const existing = Array.isArray(env.experts) ? env.experts : [];
  const installedNames = new Set(
    (Array.isArray(env.installedNames) ? env.installedNames : []).map((name) => text(name)).filter(Boolean),
  );

  const id = text(expert.id);
  const name = text(expert.name);
  const persona = text(expert.persona);
  const externalRefs = (Array.isArray(expert.externalRefs) ? expert.externalRefs : []).map(text).filter(Boolean);
  const selfId = text(env.selfId);

  // ── 1) 结构 ──────────────────────────────────────────────────────────────
  const shape = [];
  if (!id) shape.push('缺少 id（宿主靠 id 前缀识别专家预设）');
  else if (!id.startsWith('preset-')) shape.push(`id=${id} 没有 preset- 前缀`);
  else if (!id.startsWith(ID_PREFIX)) shape.push(`id=${id} 不是 ${ID_PREFIX}* 前缀，军械库面板可能识别不到`);
  if (!name) shape.push('config.name 为空（选择器里会显示成空白项）');
  const personaChars = persona.replace(/\s/g, '').length;
  if (personaChars === 0) shape.push('人设正文为空');
  else if (personaChars < MIN_PERSONA_CHARS) shape.push(`人设正文只有 ${personaChars} 个字（少于 ${MIN_PERSONA_CHARS}）`);

  const fatal = !id || !id.startsWith('preset-') || !name || personaChars === 0;
  if (shape.length === 0) {
    checks.push(pass('cand-expert-shape', '专家预设结构完整', `${id}：名称 ${name}，人设 ${personaChars} 字`));
  } else if (fatal) {
    checks.push(
      block('cand-expert-shape', '专家预设结构不完整', shape.join('；'), '补齐 id/name/人设正文再写进 profile。'),
    );
  } else {
    checks.push(
      warn(
        'cand-expert-shape',
        '专家预设存在隐患',
        shape.join('；'),
        '人设过短或 id 前缀不规范，先确认再启用。',
        'compatibility',
      ),
    );
  }

  // ── 2) 与已装专家交叉比对 ────────────────────────────────────────────────
  const siblings = existing.filter((row) => text(row?.id) !== selfId);
  const sameId = siblings.filter((row) => id && text(row?.id) === id).map((row) => text(row.id));
  const sameName = siblings
    .filter((row) => name && text(row?.name).toLowerCase() === name.toLowerCase())
    .map((row) => text(row.id) || text(row.name));
  const key = personaKey(persona);
  const samePersona = key
    ? siblings
        .filter((row) => {
          const other = personaKey(row?.persona);
          return other.length > 0 && other === key;
        })
        .map((row) => text(row.id))
    : [];

  if (sameId.length > 0) {
    checks.push(
      block(
        'cand-expert-dup',
        '专家 id 与已装专家重复',
        `${id} 已存在（${sameId.join(', ')}）；同 id 会互相覆盖，等于二选一`,
        '换一个 id，或先删掉已装的那个再装。',
        'stability',
      ),
    );
  } else if (samePersona.length > 0) {
    checks.push(
      warn(
        'cand-expert-dup',
        '人设正文与已装专家完全相同',
        `与 ${samePersona.join(', ')} 的文字内容一致，只是换了名字/ id`,
        '同一个专家没必要装两份，选择器里会重复出现。',
        'stability',
      ),
    );
  } else if (sameName.length > 0) {
    checks.push(
      warn(
        'cand-expert-dup',
        '专家名称与已装专家重复',
        `${name} 已被 ${sameName.join(', ')} 使用`,
        '名称撞车时选择器里分不清，建议改名区分。',
        'stability',
      ),
    );
  } else {
    checks.push(
      pass(
        'cand-expert-dup',
        '与已装专家无重复',
        existing.length ? `已比对 ${siblings.length} 个已装专家：id / 名称 / 人设正文均不冲突` : '本机还没有已装专家，无可比对项',
      ),
    );
  }

  // ── 3) 引用的插件是否已装 ────────────────────────────────────────────────
  // 官方 @deepseek-ai/* 由宿主自带，调用方已在 readExpertPresets 里过滤掉。
  const missing = externalRefs.filter((ref) => !installedNames.has(ref));
  if (externalRefs.length === 0) {
    checks.push(pass('cand-expert-refs', '未引用第三方插件', '人设只依赖宿主内置能力'));
  } else if (missing.length === 0) {
    checks.push(
      pass('cand-expert-refs', '引用的插件均已安装', `${externalRefs.length} 个引用：${externalRefs.join(', ')}`),
    );
  } else {
    checks.push(
      warn(
        'cand-expert-refs',
        '引用的插件尚未安装',
        `缺少：${missing.join(', ')}`,
        '先装对应插件再启用专家，否则专家会说话但工具不可用。',
      ),
    );
  }

  return checks;
}

/// 汇总成与其它模块一致的报告结构。
export function summarizeExpert(checks) {
  const blocked = checks.filter((c) => c.level === 'block').length;
  const warned = checks.filter((c) => c.level === 'warn').length;
  return {
    ok: blocked === 0,
    blocked,
    warned,
    passed: checks.filter((c) => c.level === 'pass').length,
    checks,
  };
}
