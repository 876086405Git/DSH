/**
 * 会话哨兵 —— 状态持久化（原子写）。
 *
 * 宿主退出只有 5 秒硬上限，不能依赖退出钩子：这里每次变更都写临时文件再
 * rename，保证任何时刻磁盘上都是完整 JSON。
 */
import { mkdirSync, readFileSync, renameSync, writeFileSync, unlinkSync } from 'node:fs'
import { dirname } from 'node:path'

/**
 * @param {string} filePath 状态文件绝对路径
 * @param {{ logger?: any, debounceMs?: number }} [options]
 */
export function createStore(filePath, options = {}) {
  const logger = options.logger
  const debounceMs = Number.isFinite(options.debounceMs) ? options.debounceMs : 1500
  let timer = null
  let pending = null

  function load() {
    try {
      const text = readFileSync(filePath, 'utf8')
      const data = JSON.parse(text)
      return data && typeof data === 'object' ? data : null
    } catch {
      return null
    }
  }

  function saveNow(state) {
    try {
      mkdirSync(dirname(filePath), { recursive: true })
      const tmp = filePath + '.tmp'
      writeFileSync(tmp, JSON.stringify(state), 'utf8')
      renameSync(tmp, filePath)
      return true
    } catch (error) {
      try { logger?.warn?.('session-watchdog: 状态写入失败 ' + String(error && error.message ? error.message : error)) } catch { /* noop */ }
      return false
    }
  }

  /** 合并调度：多次调用只落最后一份，最多 debounceMs 后写盘。 */
  function schedule(state) {
    pending = state
    if (timer !== null) return
    timer = setTimeout(() => {
      timer = null
      if (pending !== null) {
        saveNow(pending)
        pending = null
      }
    }, debounceMs)
    if (typeof timer.unref === 'function') timer.unref()
  }

  /** 立即落盘（turn 结束时调用，减少崩溃丢失窗口）。 */
  function flush(state) {
    if (state !== undefined) pending = state
    if (timer !== null) {
      clearTimeout(timer)
      timer = null
    }
    if (pending !== null) {
      const ok = saveNow(pending)
      pending = null
      return ok
    }
    return true
  }

  function dispose() {
    flush()
    try { unlinkSync(filePath + '.tmp') } catch { /* noop */ }
  }

  return { load, saveNow, schedule, flush, dispose, filePath }
}
