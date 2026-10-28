/**
 * dsh-prompt-enhance — 浏览器半侧（输入框「提示词增强」按钮）
 * ----------------------------------------------------------------------------
 * 以 dsh.client bundle 格式加载（手写 ModuleLoader bundle，无需构建）：
 *   - 在会话输入框工具行右侧（conversation.input.right）注册一个图标按钮；
 *   - 读取当前草稿 → POST /dsh-prompt-enhance/enhance → 直接把结果写回输入框；
 *   - 生成中显示三点波纹（不旋转），再点一次可取消；
 *   - 填入成功后按钮变成「撤回优化」，点击恢复增强前的原文；
 *   - 按钮状态由「当前草稿是否等于刚填入的增强结果」推导，输入被编辑/清空/发送后自动回到 ✨。
 *
 * 注册 id 必须等于 loader entry 名（dsh-prompt-enhance）。
 */
window.__ModuleLoader__.load({
  id: 'dsh-prompt-enhance',
  factory: function (require) {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    var React = require('react')
    var ReactDOM = require('react-dom')
    var h = React.createElement
    var useState = React.useState
    var useEffect = React.useEffect
    var useRef = React.useRef

    var API = '/dsh-prompt-enhance/enhance'
    var MAX_INPUT_CHARS = 20000
    var MAX_CLIENT_TIMEOUT_MS = 135000

    /* ── CSS ─────────────────────────────────────────────────────────────── */
    var CSS = [
      '.__dpe_root{display:inline-flex;align-items:center}',
      '.__dpe_btn{position:relative;display:inline-flex;align-items:center;justify-content:center;width:30px;height:30px;padding:0;border:1px solid transparent;border-radius:8px;background:transparent;color:var(--dsw-alias-label-secondary,#a0a4ab);cursor:pointer;transition:background .18s ease,color .18s ease,border-color .18s ease,box-shadow .18s ease;outline:none}',
      '.__dpe_btn:hover:not(:disabled){background:var(--dsw-alias-interactive-bg-hover,rgba(255,255,255,.08));color:var(--dsw-alias-label-primary,#e8e8e8)}',
      '.__dpe_btn:active:not(:disabled){background:var(--dsw-alias-interactive-bg-active,rgba(255,255,255,.12))}',
      '.__dpe_btn:focus-visible{box-shadow:0 0 0 2px var(--dsw-alias-state-business-primary,#4b6bfb)}',
      '.__dpe_btn[data-on="1"]{color:var(--dsw-alias-state-business-primary,#6c8cff);background:color-mix(in srgb,var(--dsw-alias-state-business-primary,#4b6bfb) 10%,transparent);border-color:color-mix(in srgb,var(--dsw-alias-state-business-primary,#4b6bfb) 22%,transparent)}',
      '.__dpe_btn[data-on="1"]:hover:not(:disabled){background:color-mix(in srgb,var(--dsw-alias-state-business-primary,#4b6bfb) 16%,transparent)}',
      '.__dpe_btn:disabled{opacity:.38;cursor:default}',
      /* 生成中采用无边框 + 透明背景：去掉外框线、焦点光圈和所有背景填充。 */
      '.__dpe_btn[data-state="busy"]{background:transparent;border-color:transparent;box-shadow:none}',
      '.__dpe_btn[data-state="busy"]:hover:not(:disabled),.__dpe_btn[data-state="busy"]:active:not(:disabled){background:transparent}',
      '.__dpe_sparkle{transform-origin:50% 50%;animation:__dpe_flicker 1.6s ease-in-out infinite;will-change:opacity,filter}',
      '@keyframes __dpe_flicker{0%,100%{opacity:.3;filter:brightness(.78)}50%{opacity:1;filter:brightness(1.3)}}',
      '@media (prefers-reduced-motion: reduce){.__dpe_sparkle{animation:none;opacity:1;filter:none}}',
      '.__dpe_undoIcon{display:inline-flex;animation:__dpe_undoIn .18s ease-out}',
      '@keyframes __dpe_undoIn{from{opacity:0;transform:scale(.82)}to{opacity:1;transform:scale(1)}}',
      '.__dpe_toast{position:fixed;left:50%;bottom:34px;transform:translateX(-50%);z-index:2147483000;max-width:min(560px,calc(100vw - 48px));padding:10px 14px;border-radius:10px;border:1px solid var(--dsw-alias-border-l2,rgba(255,255,255,.14));background:var(--dsw-alias-bg-layer-2,#1c1d22);color:var(--dsw-alias-label-primary,#ececec);font-size:12.5px;line-height:1.5;box-shadow:0 12px 40px rgba(0,0,0,.45);animation:__dpe_toastIn .16s ease-out}',
      '.__dpe_toast[data-tone="error"]{border-color:color-mix(in srgb,var(--dsw-alias-state-error-primary,#f05f5f) 55%,transparent);color:var(--dsw-alias-state-error-primary,#ff8a8a)}',
      '@keyframes __dpe_toastIn{from{opacity:0;transform:translate(-50%,6px)}to{opacity:1;transform:translate(-50%,0)}}',
    ].join('')

    var CSS_ID = 'dsh-prompt-enhance/main.css'
    if (typeof document !== 'undefined' && document.querySelector('style[data-plugin-css="' + CSS_ID + '"]') === null) {
      var styleTag = document.createElement('style')
      styleTag.dataset.plugin = 'dsh-prompt-enhance'
      styleTag.dataset.pluginCss = CSS_ID
      styleTag.textContent = CSS
      document.head.appendChild(styleTag)
    }

    /* ── 图标 ────────────────────────────────────────────────────────────── */
    function iconSparkles(size, className) {
      return h('svg', {
        width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': 'true', focusable: 'false', className: className,
      },
        h('path', { d: 'M10 3.2 11.55 7.4 15.75 8.95 11.55 10.5 10 14.7 8.45 10.5 4.25 8.95 8.45 7.4Z' }),
        h('path', { d: 'M17.5 13.6 18.45 16 20.85 16.95 18.45 17.9 17.5 20.3 16.55 17.9 14.15 16.95 16.55 16Z' }),
        h('path', { d: 'M17.2 3.4v2.2M16.1 4.5h2.2' }),
      )
    }

    function iconUndo(size) {
      return h('svg', {
        width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.8, strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': 'true', focusable: 'false', className: '__dpe_undoIcon',
      },
        h('path', { d: 'M9 14 4 9l5-5' }),
        h('path', { d: 'M4 9h10.5a5.5 5.5 0 0 1 0 11H12' }),
      )
    }

    function Portal(props) {
      var ref = useRef(null)
      if (ref.current === null && typeof document !== 'undefined') {
        var host = document.createElement('div')
        host.setAttribute('data-dsh-plugin', 'dsh-prompt-enhance')
        ref.current = host
      }
      useEffect(function () {
        var host = ref.current
        if (!host || !document.body) return undefined
        document.body.appendChild(host)
        return function () {
          try { if (host.parentNode) host.parentNode.removeChild(host) } catch (err) { /* noop */ }
        }
      }, [])
      if (!ref.current) return null
      return ReactDOM.createPortal(props.children, ref.current)
    }

    /* ── 语义草稿：保留文件/文件夹/会话引用芯片 ──────────────────────────── */
    var REFERENCE_APPEARANCES = { session: 1, file: 1, folder: 1 }

    /** 复制一条引用投影，丢掉 occurrenceId 等编辑器内部字段；不合法返回 null。 */
    function copyReference(reference) {
      if (!reference || typeof reference !== 'object') return null
      if (typeof reference.source !== 'string' || reference.source === '') return null
      if (typeof reference.ref !== 'string') return null
      if (typeof reference.label !== 'string') return null
      if (typeof reference.clipboardText !== 'string' || reference.clipboardText === '') return null
      if (typeof reference.offset !== 'number' || typeof reference.length !== 'number') return null
      if (reference.length !== reference.clipboardText.length) return null
      var copy = {
        source: reference.source,
        ref: reference.ref,
        offset: reference.offset,
        length: reference.length,
        label: reference.label,
        clipboardText: reference.clipboardText,
      }
      if (typeof reference.appearance === 'string' && REFERENCE_APPEARANCES[reference.appearance]) {
        copy.appearance = reference.appearance
      }
      if (reference.invalid === true) copy.invalid = true
      return copy
    }

    /** 当前草稿里仍然对得上位置的引用（按 offset 排序）。 */
    function collectReferences(text, occurrences) {
      var list = []
      if (typeof text !== 'string' || !Array.isArray(occurrences)) return list
      for (var i = 0; i < occurrences.length; i += 1) {
        var copy = copyReference(occurrences[i])
        if (!copy) continue
        if (text.slice(copy.offset, copy.offset + copy.length) !== copy.clipboardText) continue
        list.push(copy)
      }
      list.sort(function (a, b) { return a.offset - b.offset })
      return list
    }

    /** 增强前的草稿快照：没有引用就是普通字符串，有引用才传宿主的结构化草稿。 */
    function buildOriginalDraft(text, occurrences) {
      var value = typeof text === 'string' ? text : String(text == null ? '' : text)
      var references = collectReferences(value, occurrences)
      if (references.length === 0) return value
      return { text: value, references: references }
    }

    /** 把原引用文本按顺序映射到增强结果里；找不到的引用降级为纯文本。 */
    function mapReferencesToText(text, occurrences) {
      var mapped = []
      if (typeof text !== 'string' || !Array.isArray(occurrences)) return mapped
      var candidates = []
      for (var i = 0; i < occurrences.length; i += 1) {
        var copy = copyReference(occurrences[i])
        if (copy) candidates.push(copy)
      }
      candidates.sort(function (a, b) { return a.offset - b.offset })
      var cursor = 0
      for (var j = 0; j < candidates.length; j += 1) {
        var reference = candidates[j]
        var at = text.indexOf(reference.clipboardText, cursor)
        if (at < 0) continue
        reference.offset = at
        reference.length = reference.clipboardText.length
        mapped.push(reference)
        cursor = at + reference.length
      }
      return mapped
    }

    /** 增强后的草稿值：能映射到引用就传结构化草稿，否则退回纯字符串。 */
    function buildEnhancedDraft(text, occurrences) {
      var value = typeof text === 'string' ? text : String(text == null ? '' : text)
      var references = mapReferencesToText(value, occurrences)
      if (references.length === 0) return value
      return { text: value, references: references }
    }

    /* ── 输入框按钮 ──────────────────────────────────────────────────────── */
    function PromptEnhanceButton(props) {
      var useInput = props.useInput
      var inputActions = props.inputActions
      var input = typeof useInput === 'function' ? useInput(function (state) { return state }) : undefined
      var draft = input && typeof input.draft === 'string' ? input.draft : ''
      var occurrences = input && Array.isArray(input.occurrences) ? input.occurrences : []
      var phase = input && typeof input.phase === 'string' ? input.phase : undefined
      var locked = phase !== undefined && phase !== 'plain'
      var [busy, setBusy] = useState(false)
      var [undo, setUndo] = useState(null)
      var [toast, setToast] = useState(null)
      var controllerRef = useRef(null)
      var requestSeq = useRef(0)
      var mountedRef = useRef(true)
      var toastTimer = useRef(null)
      var draftRef = useRef(draft)
      draftRef.current = draft

      useEffect(function () {
        mountedRef.current = true
        return function () {
          mountedRef.current = false
          try { if (controllerRef.current) controllerRef.current.abort() } catch (err) { /* noop */ }
          if (toastTimer.current) { clearTimeout(toastTimer.current); toastTimer.current = null }
        }
      }, [])

      /* 切换会话时丢掉上一条的撤销记录与在途请求，避免跨会话误撤回。 */
      useEffect(function () {
        setUndo(null)
        abortRequest()
        return undefined
      }, [props.sessionId])

      function showToast(text, tone) {
        if (!mountedRef.current) return
        setToast({ text: String(text), tone: tone === 'error' ? 'error' : 'info', id: Date.now() })
      }

      useEffect(function () {
        if (!toast) return undefined
        if (toastTimer.current) clearTimeout(toastTimer.current)
        toastTimer.current = setTimeout(function () {
          toastTimer.current = null
          if (mountedRef.current) setToast(null)
        }, 4200)
        return function () {
          if (toastTimer.current) { clearTimeout(toastTimer.current); toastTimer.current = null }
        }
      }, [toast])

      function abortRequest() {
        requestSeq.current += 1
        if (controllerRef.current) {
          try { controllerRef.current.abort() } catch (err) { /* noop */ }
          controllerRef.current = null
        }
        if (mountedRef.current) setBusy(false)
      }

      /** 优先写结构化草稿（保留引用芯片），宿主拒绝时退回纯文本。 */
      function writeDraft(value, fallbackText) {
        if (!inputActions || typeof inputActions.setDraft !== 'function') return false
        var candidates = [value]
        if (value !== null && typeof value === 'object') candidates.push(fallbackText)
        var lastError = null
        for (var i = 0; i < candidates.length; i += 1) {
          var candidate = candidates[i]
          if (typeof candidate !== 'string' && (candidate === null || typeof candidate !== 'object')) continue
          try {
            inputActions.setDraft(candidate)
            return true
          } catch (error) {
            lastError = error
          }
        }
        showToast('写入输入框失败：' + (lastError && lastError.message ? lastError.message : '未知错误'), 'error')
        return false
      }

      function requestEnhancement(text) {
        var originalDraft = buildOriginalDraft(text, occurrences)
        var seq = ++requestSeq.current
        if (controllerRef.current) {
          try { controllerRef.current.abort() } catch (err) { /* noop */ }
        }
        var controller = typeof AbortController === 'function' ? new AbortController() : null
        controllerRef.current = controller
        setBusy(true)
        var timer = controller ? setTimeout(function () {
          try { controller.abort() } catch (err) { /* noop */ }
        }, MAX_CLIENT_TIMEOUT_MS) : null

        var options = {
          method: 'POST',
          credentials: 'same-origin',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: JSON.stringify({
            text: text,
            sessionId: typeof props.sessionId === 'string' ? props.sessionId : undefined,
          }),
        }
        if (controller) options.signal = controller.signal

        fetch(API, options)
          .then(function (response) {
            return response.text().then(function (raw) {
              var data = null
              try { data = raw ? JSON.parse(raw) : null } catch (err) { data = null }
              if (!response.ok || !data || data.ok !== true) {
                var message = data && data.error && data.error.message
                  ? data.error.message
                  : '增强请求失败（HTTP ' + response.status + '）'
                var failure = new Error(message)
                failure.code = data && data.error ? data.error.code : 'HTTP_' + response.status
                throw failure
              }
              return data
            })
          })
          .then(function (data) {
            if (seq !== requestSeq.current || !mountedRef.current) return
            setBusy(false)
            controllerRef.current = null
            var latest = draftRef.current
            if (latest !== text) {
              showToast('输入内容在增强期间已变化，本次结果未填入，请重试')
              return
            }
            var enhanced = data && typeof data.text === 'string' ? data.text : ''
            if (!enhanced) {
              showToast('模型没有返回可用的增强结果', 'error')
              return
            }
            if (enhanced.trim() === text.trim()) {
              showToast('原文已经足够清晰，模型没有做实质改动')
              return
            }
            var enhancedDraft = buildEnhancedDraft(enhanced, occurrences)
            if (!writeDraft(enhancedDraft, enhanced)) return
            setUndo({ original: originalDraft, originalText: text, enhanced: enhanced })
            var keptRefs = enhancedDraft && typeof enhancedDraft === 'object' && Array.isArray(enhancedDraft.references)
              ? enhancedDraft.references.length
              : 0
            showToast(keptRefs > 0
              ? '已自动填入增强结果 · 保留 ' + keptRefs + ' 个引用；点 ↺ 恢复原文'
              : '已自动填入增强结果 · 可直接编辑或发送；点 ↺ 恢复原文')
          })
          .catch(function (error) {
            if (seq !== requestSeq.current || !mountedRef.current) return
            controllerRef.current = null
            setBusy(false)
            if (error && (error.name === 'AbortError' || error.code === 'ABORTED')) return
            var message = error && error.message ? error.message : '增强失败，请稍后重试'
            if (error && error.name === 'TypeError') message = '无法连接增强服务：宿主没有注册 /dsh-prompt-enhance 路由'
            showToast(message, 'error')
          })
          .then(function () { if (timer) clearTimeout(timer) })
      }

      function undoEnhancement() {
        if (!undo) return
        var record = undo
        setUndo(null)
        if (writeDraft(record.original, record.originalText)) showToast('已恢复优化前的内容')
      }

      var undoActive = !!undo && !busy && draft === undo.enhanced

      function onTrigger() {
        if (busy) { abortRequest(); return }
        if (undoActive) { undoEnhancement(); return }
        var text = draft
        if (text.trim() === '') { showToast('先输入内容，再点提示词增强'); return }
        if (text.length > MAX_INPUT_CHARS) {
          showToast('当前 ' + text.length + ' 字符，超过 ' + MAX_INPUT_CHARS + ' 字上限；请精简后再试', 'error')
          return
        }
        if (locked) { showToast('输入框正在提交或不可编辑，请稍后再试', 'error'); return }
        requestEnhancement(text)
      }

      var disabled = !inputActions || (locked && !busy)
      var title = busy
        ? '正在增强，点击取消'
        : undoActive
          ? '撤回提示词优化，恢复增强前的内容'
          : draft.trim() === ''
            ? '提示词增强：先在输入框里写下内容'
            : '提示词增强：把当前输入改写为更清晰、具体的提示词'
      var ariaLabel = busy ? '正在增强，点击取消' : undoActive ? '撤回提示词优化' : '提示词增强'

      var button = h('button', {
        type: 'button',
        className: '__dpe_btn',
        disabled: disabled,
        'data-on': busy || undoActive ? '1' : undefined,
        'data-state': busy ? 'busy' : undoActive ? 'undo' : 'idle',
        'aria-label': ariaLabel,
        'aria-busy': busy ? 'true' : undefined,
        title: title,
        onMouseDown: function (event) {
          /* 保住编辑器焦点/选区，与工具行其它按钮一致 */
          if (event && typeof event.preventDefault === 'function') event.preventDefault()
        },
        onClick: onTrigger,
      }, busy ? iconSparkles(16, '__dpe_sparkle') : undoActive ? iconUndo(16) : iconSparkles(16))

      return h(React.Fragment, null,
        h('span', { className: '__dpe_root', 'data-plugin': 'dsh-prompt-enhance' }, button),
        toast ? h(Portal, null,
          h('div', { className: '__dpe_toast', 'data-tone': toast.tone, role: 'status' }, toast.text),
        ) : null,
      )
    }

    /* ── 插件 ────────────────────────────────────────────────────────────── */
    var inject = ['slots']

    function apply(ctx) {
      ctx.slots.inject('conversation.input.right', function () {
        return ctx.slots.register(
          {
            name: 'conversation.input.right',
            id: 'prompt-enhance',
            order: 30,
            label: '提示词增强',
            inject: function (sessionId) { return { sessionId: sessionId } },
          },
          PromptEnhanceButton,
        )
      })
    }

    exports.apply = apply
    exports.inject = inject
    /* 仅测试用：Node 侧从 bundle 里取出纯函数，验证引用映射。 */
    exports.__draftReferences = {
      copyReference: copyReference,
      collectReferences: collectReferences,
      buildOriginalDraft: buildOriginalDraft,
      mapReferencesToText: mapReferencesToText,
      buildEnhancedDraft: buildEnhancedDraft,
    }
    return module.exports
  },
});
