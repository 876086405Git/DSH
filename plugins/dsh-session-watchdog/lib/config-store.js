/**
 * 会话哨兵 —— 运行时可改配置。
 *
 * 优先级：持久化覆盖（config.json） > cordis.patch.yml 的静态 config > DEFAULT_CONFIG。
 * 设置面板通过 POST /dsh-session-watchdog/config 写入这里，宿主半侧立刻生效（无需重启）。
 */
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { DEFAULT_CONFIG, normalizeConfig } from './policy.js'

/** 设置面板允许改的字段（白名单，其余字段不可由 UI 写入）。 */
export const EDITABLE_FIELDS = [
  'enabled',
  'autoResume',
  'monitorSubagents',
  'resumeOnStall',
  'resumeOnStartupScan',
  'skipWhenAwaitingUser',
  'resumeKinds',
  'includeCwd',
  'excludeCwd',
  'excludeSessionIds',
  'notifyOnCompletion',
  'notifyOnAborted',
  'notifyOnStall',
  'notifyOs',
  'notifyGui',
  'toastDurationMs',
  'completionSound',
  'completionVolume',
  'resumePromptMode',
  'stallTimeoutMs',
  'toolStallTimeoutMs',
  'resumeDelayMs',
  'maxResumesPerSession',
  'globalBudget',
  'maxConsecutiveFailures',
  'maxContextChars',
]

const SETTINGS_VERSION = 1

function pickEditable(source) {
  const out = {}
  for (const key of EDITABLE_FIELDS) {
    if (source && Object.prototype.hasOwnProperty.call(source, key)) out[key] = source[key]
  }
  return out
}

/**
 * @param {{filePath:string, base?:any, logger?:any}} options
 */
export function createConfigStore(options) {
  const filePath = options.filePath
  const base = options.base && typeof options.base === 'object' ? options.base : {}
  const logger = options.logger
  let overrides = {}
  let updatedAt = 0

  try {
    const text = readFileSync(filePath, 'utf8')
    const data = JSON.parse(text)
    if (data && typeof data === 'object' && data.overrides && typeof data.overrides === 'object') {
      overrides = pickEditable(data.overrides)
      updatedAt = Number.isFinite(data.updatedAt) ? data.updatedAt : 0
    }
  } catch {
    /* 文件不存在或损坏：从静态配置开始 */
  }

  let current = normalizeConfig({ ...base, ...overrides })

  function save() {
    try {
      mkdirSync(dirname(filePath), { recursive: true })
      const tmp = filePath + '.tmp'
      writeFileSync(tmp, JSON.stringify({ version: SETTINGS_VERSION, updatedAt, overrides }), 'utf8')
      renameSync(tmp, filePath)
      return true
    } catch (error) {
      try { logger?.warn?.('session-watchdog: 配置写入失败 ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
      return false
    }
  }

  /** 写一组字段（partial）。返回 { ok, config } 或 { ok:false, error }。 */
  function update(patch) {
    if (!patch || typeof patch !== 'object' || Array.isArray(patch)) return { ok: false, error: 'invalid-patch' }
    const accepted = pickEditable(patch)
    if (Object.keys(accepted).length === 0) return { ok: false, error: 'no-editable-field' }
    overrides = { ...overrides, ...accepted }
    updatedAt = Date.now()
    current = normalizeConfig({ ...base, ...overrides })
    const saved = save()
    return { ok: true, config: current, persisted: saved }
  }

  /** 清空运行时覆盖，回到 patch 静态配置。 */
  function reset() {
    overrides = {}
    updatedAt = Date.now()
    current = normalizeConfig({ ...base })
    const saved = save()
    return { ok: true, config: current, persisted: saved }
  }

  /** 设置面板需要的完整载荷（只读）。 */
  function payload() {
    return {
      version: SETTINGS_VERSION,
      editable: EDITABLE_FIELDS.slice(),
      config: { ...current },
      defaults: { ...DEFAULT_CONFIG },
      updatedAt,
      filePath,
    }
  }

  return { get: () => current, update, reset, payload, resetToBase: reset, filePath }
}
