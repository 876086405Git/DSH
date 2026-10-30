// Install Guard — Skill 检查
//
// skill 没有"安装 API"：它就是一个目录（~/.dsh/skills/<name>/），由文件系统 provider 发现。
// 所以这里做的是「装前检查一个候选目录」+「装后体检已装 skill」两件事，纯函数便于测试。
import { createHash } from 'node:crypto';

const pass = (id, title, detail, category = 'stability') => ({ id, category, level: 'pass', title, detail });
const warn = (id, title, detail, hint, category = 'stability') => ({ id, category, level: 'warn', title, detail, hint });
const block = (id, title, detail, hint, category = 'stability') => ({ id, category, level: 'block', title, detail, hint });


const NAME_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/i;

/// SKILL.md 正文指纹：用于识别「同一份技能换个目录名重装」。
export function skillContentHash(text) {
  const normalized = String(text == null ? '' : text).replace(/\r\n/g, '\n').trim();
  if (!normalized) return '';
  return createHash('sha256').update(normalized).digest('hex').slice(0, 16);
}

/// 解析 SKILL.md 的 YAML frontmatter（只取标量字段，够用且无依赖）。
export function parseFrontmatter(text) {
  if (typeof text !== 'string') return undefined;
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (!match) return undefined;
  const out = {};
  for (const line of match[1].split(/\r?\n/)) {
    const m = /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line.trim());
    if (!m) continue;
    let value = m[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (value) out[m[1]] = value;
  }
  return out;
}

/// SKILL.md 里如果直接教用户跑「下载即执行」的命令，也该提示。
const INSTRUCTION_RISKS = [
  { re: /\bcurl\b[^\n|]{0,120}\|\s*(?:ba)?sh\b/i, why: '文档里教用户 curl 管道执行' },
  { re: /\bwget\b[^\n|]{0,120}\|\s*(?:ba)?sh\b/i, why: '文档里教用户 wget 管道执行' },
  { re: /powershell[^\n]{0,80}-(?:enc|encodedcommand)\b/i, why: '文档里出现 PowerShell 编码命令' },
  { re: /chmod\s+\+x[^\n]{0,40}&&\s*\.\//i, why: '下载后直接赋权执行' },
];

export function scanSkillInstructions(text) {
  if (typeof text !== 'string' || !text) return [];
  return INSTRUCTION_RISKS.filter((rule) => rule.re.test(text)).map((rule) => rule.why);
}

/// 检查一个候选 skill 目录（由 host 读成 { files: [{ path, text }] } 传入）。
export function checkSkill({ name, dirPath, files, existingNames, existingSkills, scriptHits }) {
  const checks = [];
  const list = Array.isArray(files) ? files : [];
  const skillMd = list.find((f) => /(?:^|\/)SKILL\.md$/i.test(f.path));
  const baseName = (name || (dirPath ? dirPath.split(/[\\/]/).filter(Boolean).pop() : '') || '').trim();
  // frontmatter 在「SKILL.md 完整性」和后面的「改名同一份」两处都要用，提到外面算一次。
  const meta = skillMd ? parseFrontmatter(skillMd.text || '') : undefined;

  // 1) SKILL.md 与 frontmatter
  if (!skillMd) {
    checks.push(
      block(
        'sk-manifest',
        '缺少 SKILL.md',
        `目录里没有 SKILL.md，宿主不会把它识别为 skill`,
        '补一个带 frontmatter（name/description）的 SKILL.md。',
        'stability',
      ),
    );
  } else {
    if (!meta || !meta.name || !meta.description) {
      checks.push(
        warn(
          'sk-manifest',
          'SKILL.md frontmatter 不完整',
          `缺少 ${[meta && meta.name ? null : 'name', meta && meta.description ? null : 'description'].filter(Boolean).join(' / ')}`,
          '补全 frontmatter 后模型才能正确路由到该 skill。',
          'stability',
        ),
      );
    } else {
      checks.push(pass('sk-manifest', 'SKILL.md frontmatter 完整', `name=${meta.name}`));
    }
  }

  // 2) 目录名与命名规范
  if (!baseName) {
    checks.push(warn('sk-name', '无法确定 skill 名称', '目录名为空', '确认安装路径。', 'stability'));
  } else if (!NAME_PATTERN.test(baseName)) {
    checks.push(
      warn(
        'sk-name',
        'skill 名称不符合命名规范',
        `${baseName}（应匹配 ${NAME_PATTERN.source}）`,
        '改成小写字母/数字/连字符，避免宿主解析失败。',
        'stability',
      ),
    );
  } else if (Array.isArray(existingNames) && existingNames.includes(baseName)) {
    checks.push(
      warn(
        'sk-name',
        '同名 skill 已存在',
        `${baseName} 已安装；同名时高优先级来源会覆盖另一个`,
        '先卸载同名 skill 再装。',
        'compatibility',
      ),
    );
  } else {
    checks.push(pass('sk-name', 'skill 名称可用', baseName, 'compatibility'));
  }

  // 3) 脚本扫描（安全性）
  const hits = Array.isArray(scriptHits) ? scriptHits : [];
  const blocking = hits.filter((h) => h.level === 'block');
  if (hits.length === 0) {
    checks.push(pass('sk-scripts', 'skill 脚本未命中危险特征', '未发现凭据读取、下载即执行、混淆执行等模式', 'security'));
  } else if (blocking.length > 0) {
    checks.push(
      block(
        'sk-scripts',
        'skill 脚本命中隐私泄露或恶意代码特征',
        blocking.map((h) => `${h.file}: ${h.why}`).join('；'),
        '立即停止安装，检查该脚本内容。',
        'security',
      ),
    );
  } else {
    checks.push(
      warn(
        'sk-scripts',
        'skill 脚本命中可疑特征',
        hits.map((h) => `${h.file}: ${h.why}`).join('；'),
        '确认这些调用只用于合法用途。',
        'security',
      ),
    );
  }

  // 4) SKILL.md 里的危险指令
  const instructionRisks = skillMd ? scanSkillInstructions(skillMd.text || '') : [];
  if (instructionRisks.length === 0) {
    checks.push(pass('sk-instructions', 'SKILL.md 未要求高风险命令', '未出现下载即执行/编码执行等写法', 'security'));
  } else {
    checks.push(
      warn(
        'sk-instructions',
        'SKILL.md 要求高风险命令',
        instructionRisks.join('；'),
        '模型可能照做，确认该流程是否必要。',
        'security',
      ),
    );
  }

  // 5) 依赖声明
  const hasRequirements = list.some((f) => /requirements\.txt$/i.test(f.path));
  const hasPackageJson = list.some((f) => /(?:^|\/)package\.json$/i.test(f.path));
  if (!hasRequirements && !hasPackageJson) {
    checks.push(pass('sk-deps', '无额外依赖声明', 'skill 仅靠文档与宿主工具工作'));
  } else {
    checks.push(
      pass(
        'sk-deps',
        '存在依赖声明',
        [hasRequirements ? 'requirements.txt' : null, hasPackageJson ? 'package.json' : null].filter(Boolean).join(' + '),
      ),
    );
  }

  // 6) 规模
  const count = list.length;
  if (count > 500) {
    checks.push(
      warn('sk-size', 'skill 文件数量偏多', `${count} 个文件`, '超大 skill 会拖慢扫描与加载。', 'stability'),
    );
  } else {
    checks.push(pass('sk-size', 'skill 规模正常', `${count} 个文件`));
  }

  // 7) 交叉比对：与已装技能是否「同一份换个名字」
  //    目录名相同由 sk-name 负责；这里查的是改名后仍能认出来的重复：
  //    SKILL.md 正文指纹一致，或 frontmatter 的 name 撞车。
  const installed = (Array.isArray(existingSkills) ? existingSkills : []).filter(
    (row) => row && typeof row === 'object' && row.dirName !== baseName,
  );
  const myHash = skillMd ? skillContentHash(skillMd.text || '') : '';
  const myDeclared = meta && meta.name ? String(meta.name).trim().toLowerCase() : '';
  const sameHash = myHash ? installed.filter((row) => row.hash && row.hash === myHash).map((row) => row.dirName) : [];
  const sameDeclared = myDeclared
    ? installed
        .filter((row) => row.skillName && String(row.skillName).trim().toLowerCase() === myDeclared)
        .map((row) => row.dirName)
    : [];

  if (!skillMd) {
    checks.push(pass('dup-skill-content', '无 SKILL.md 可比对', '缺 SKILL.md 已由 sk-manifest 报出，跳过内容比对'));
  } else if (sameHash.length > 0) {
    checks.push(
      warn(
        'dup-skill-content',
        '与已装技能内容完全相同',
        `${sameHash.join(', ')} 的 SKILL.md 正文与候选一字不差，只是目录名不同`,
        '改名重装等于装两份同一技能，删掉多余的那份。',
        'stability',
      ),
    );
  } else if (sameDeclared.length > 0) {
    checks.push(
      warn(
        'dup-skill-content',
        'SKILL.md 声明的 name 与已装技能重复',
        `frontmatter name=${myDeclared}，已被 ${sameDeclared.join(', ')} 使用`,
        '模型按 name 路由，两个同名技能会互相干扰。',
        'stability',
      ),
    );
  } else {
    checks.push(
      pass(
        'dup-skill-content',
        '与已装技能无重复',
        installed.length
          ? `已比对 ${installed.length} 个已装技能：正文指纹与 frontmatter name 均不冲突`
          : '本机还没有其它已装技能',
      ),
    );
  }

  return checks;
}
