package io.github.ccch1mneyyy.dsh_app.pet

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import java.io.ByteArrayInputStream

/** One disposable renderer inside PetView. It owns no window, gestures, service or retry budget. */
@SuppressLint("SetJavaScriptEnabled")
internal class CompanionFloatView(
    context: Context,
    private val endpoint: CompanionFloatEndpoint,
    private val geometry: CompanionFloatGeometry,
    private val listener: Listener,
) {
    interface Listener {
        fun bounds(box: FramePx?)
        fun failed(code: String)
        fun resumeNeeded()
    }

    private val main = Handler(Looper.getMainLooper())
    private var closed = false
    private var rendererGone = false
    private var ready = false
    private var seenBounds = false
    private var state = PetPack.IDLE
    private var reduced = false
    private val freezing = CompanionFloatFreeze()
    private val timeout = Runnable { fail("companion_start_timeout") }

    val view = WebView(context.applicationContext)

    init {
        try { configure() } catch (failure: RuntimeException) {
            closed = true
            try { view.destroy() } catch (_: RuntimeException) {}
            throw failure
        }
    }

    private fun configure() = view.apply {
        setBackgroundColor(Color.TRANSPARENT)
        isFocusable = false
        isFocusableInTouchMode = false
        isLongClickable = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        overScrollMode = View.OVER_SCROLL_NEVER
        isVerticalScrollBarEnabled = false
        isHorizontalScrollBarEnabled = false
        settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            domStorageEnabled = false
            databaseEnabled = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE
        }
        addJavascriptInterface(object {
            @JavascriptInterface fun postMessage(raw: String) {
                if (raw.length > 4096) return
                main.post { if (!closed) message(raw) }
            }
        }, "DshCompanion")
        webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) = request.deny()
            // Never send token-bearing local URLs or model errors to logcat.
            override fun onConsoleMessage(message: ConsoleMessage) = true
        }
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
                !endpoint.owns(request.url.toString())

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                if (endpoint.owns(request.url.toString())) null else
                    WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(byteArrayOf()))

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) fail("companion_load_failed")
            }

            override fun onPageFinished(view: WebView, url: String) {
                if (!closed && !view.isHardwareAccelerated) fail("companion_hardware_unavailable")
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                rendererGone = true
                fail("companion_renderer_gone")
                return true
            }
        }
    }

    fun start() {
        main.postDelayed(timeout, 15_000)
        view.loadUrl(endpoint.page)
    }

    fun state(next: String, reduceMotion: Boolean) {
        if (state == next && reduced == reduceMotion) return
        state = next
        reduced = reduceMotion
        if (ready) sendState()
    }

    private fun sendState() {
        command(JSONObject().put("type", "petState").put("state", state).put("reduceMotion", reduced))
    }

    /** Same stage commands used by the room; no script text is interpolated. */
    fun companionLine(emotion: String, chars: Int, speaking: Boolean) {
        if (!ready || closed) return
        command(JSONObject().put("type", "emotion").put("name", emotion).put("hold", 2600))
        command(JSONObject().put("type", "mood").put("mood", if (speaking) "speaking" else "idle"))
        if (speaking) command(JSONObject().put("type", "say").put("chars", chars))
    }

    fun speech(chars: Int, speaking: Boolean) {
        if (!ready || closed) return
        command(JSONObject().put("type", "mood").put("mood", if (speaking) "speaking" else "idle"))
        if (speaking) command(JSONObject().put("type", "say").put("chars", chars))
        else command(JSONObject().put("type", "quiet"))
    }

    /** A tap at ([x], [y]) in 0–1 of the viewport. */
    fun tap(x: Float, y: Float) {
        if (ready) command(JSONObject().put("type", "tap").put("x", x.toDouble()).put("y", y.toDouble()))
    }

    fun freeze(next: Boolean) {
        freezeCommand(freezing.request(next))
    }

    private fun freezeCommand(type: String?) {
        if (type != null) command(JSONObject().put("type", type))
    }

    private fun command(value: JSONObject) {
        if (!closed) view.evaluateJavascript("window.stage?.command($value)", null)
    }

    private fun message(raw: String) {
        val json = try { JSONObject(raw) } catch (_: Exception) { return fail("companion_protocol_failed") }
        when (json.optString("type")) {
            "floatReady" -> {
                ready = true
                sendState()
                freezeCommand(freezing.onReady())
            }
            "floatBounds" -> {
                val value = json.optJSONObject("bounds")
                if (value == null) {
                    // Shader preparation may leave the first buffer empty. Keep its
                    // startup deadline; do not hide the page before its first picture.
                    if (seenBounds) listener.bounds(null)
                } else {
                    val box = geometry.fromBuffer(json.optInt("width"), json.optInt("height"), FramePx(
                        value.optInt("left", -1), value.optInt("top", -1),
                        value.optInt("right", -1), value.optInt("bottom", -1),
                    )) ?: return fail("companion_protocol_failed")
                    seenBounds = true
                    main.removeCallbacks(timeout)
                    listener.bounds(box)
                    freezeCommand(freezing.onPicture())
                }
            }
            "floatError" -> fail(if (json.optString("code") == "companion_context_lost")
                "companion_context_lost" else "companion_render_failed")
            "floatResume" -> listener.resumeNeeded()
        }
    }

    private fun fail(code: String) {
        if (!closed) listener.failed(code)
    }

    /** Remove first, then destroy; a renderer-gone WebView is never reused. */
    fun close() {
        if (closed) return
        closed = true
        ready = false
        main.removeCallbacks(timeout)
        try {
            if (!rendererGone) {
                view.evaluateJavascript("window.stage?.command({type:'dispose'})", null)
                view.removeJavascriptInterface("DshCompanion")
                view.stopLoading()
                view.onPause()
            }
        } catch (_: RuntimeException) {
            // A provider can disappear between its last callback and this turn.
        } finally {
            (view.parent as? ViewGroup)?.removeView(view)
            view.destroy()
        }
    }
}
