package io.github.ccch1mneyyy.dsh_app.text

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.systemchannels.ProcessTextChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.text.ProcessTextPlugin

/**
 * Other apps' text actions (翻译, 搜索…) for the selection toolbar, asked of [inner] once.
 *
 * Flutter's SelectableRegion asks for them as it is created, and every chat message is one:
 * opening or scrolling a long conversation asked again for each message that came into view.
 * The engine's plugin keeps the list of apps from its first answer but loads each app's label
 * again on every ask, on the thread that also runs Dart. This keeps the labels as well, until
 * [forget]: back in the foreground (another app may have changed) or a configuration change
 * (the language).
 */
class CachedTextActions(
    private val inner: ProcessTextChannel.ProcessTextMethodHandler,
) : ProcessTextChannel.ProcessTextMethodHandler {
    private var actions: Map<String, String>? = null

    override fun queryTextActions(): Map<String, String> =
        actions ?: inner.queryTextActions().also { actions = it }

    override fun processTextAction(id: String, text: String, readOnly: Boolean, result: MethodChannel.Result) =
        inner.processTextAction(id, text, readOnly, result)

    fun forget() {
        actions = null
    }

    companion object {
        /** In front of the engine's own handler; null when the engine has none (nothing changes). */
        fun install(engine: FlutterEngine): CachedTextActions? {
            val plugin = engine.plugins.get(ProcessTextPlugin::class.java) as? ProcessTextPlugin ?: return null
            return CachedTextActions(plugin).also { engine.processTextChannel.setMethodHandler(it) }
        }
    }
}
