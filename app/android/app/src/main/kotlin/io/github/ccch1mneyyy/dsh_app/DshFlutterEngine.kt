package io.github.ccch1mneyyy.dsh_app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.files.FilesPlugin
import io.github.ccch1mneyyy.dsh_app.links.LinksPlugin
import io.github.ccch1mneyyy.dsh_app.notify.NotifyPlugin
import io.github.ccch1mneyyy.dsh_app.phone.PhonePlugin
import io.github.ccch1mneyyy.dsh_app.remote.RemoteBackgroundService
import io.github.ccch1mneyyy.dsh_app.runtime.RuntimePlugin
import io.github.ccch1mneyyy.dsh_app.share.SharePlugin
import io.github.ccch1mneyyy.dsh_app.shortcuts.ShortcutsPlugin
import io.github.ccch1mneyyy.dsh_app.update.UpdatePlugin
import io.github.ccch1mneyyy.dsh_app.voice.VoicePlugin

/** Activity and the companion service own leases on this same process engine. */
object DshFlutterEngine {
    const val ENGINE_ID = "dsh-main"

    @Synchronized
    fun getOrCreate(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val appContext = context.applicationContext
        return FlutterEngine(appContext).also { engine ->
            val runtime = RuntimePlugin()
            engine.plugins.add(runtime)
            engine.plugins.add(PhonePlugin())
            engine.plugins.add(NotifyPlugin())
            engine.plugins.add(FilesPlugin())
            engine.plugins.add(LinksPlugin())
            engine.plugins.add(UpdatePlugin())
            engine.plugins.add(VoicePlugin())
            engine.plugins.add(SharePlugin())
            engine.plugins.add(ShortcutsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.diagnostics.DiagnosticsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.media.MediaPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.media.MediaVideoPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.icons.LauncherIconPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.theme.DynamicColorPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.performance.PerformancePlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.pet.PetOverlayPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.islands.IslandsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.nativemedia.NativeMediaPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.nativefiles.NativeFilesPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.web.WebFilesPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.launch.LaunchPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.launch.LaunchClipPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.icons.PictureShortcutPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.usage.UsagePlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionVoicePlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.speech.SpeechPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionWidgetPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionReminderPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionMapPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionEmbeddingPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionNoticesPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.companion.CompanionAlwaysOnPlugin())
            // A disconnect can arrive after MainActivity has detached from this cached engine.
            MethodChannel(
                engine.dartExecutor.binaryMessenger, "io.github.ccch1mneyyy.dsh_app/remote_background",
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestRemoteLocation" -> runtime.requestRemoteLocation(result)
                    "setRemoteActive", "setRemoteAudio", "setRemoteLocation" -> {
                        val enabled = call.arguments as? Boolean
                        if (enabled == null) {
                            result.error("bad_args", "Expected a boolean", null)
                        } else {
                            when (call.method) {
                                "setRemoteActive" -> RemoteBackgroundService.setRemoteActive(appContext, enabled)
                                "setRemoteAudio" -> RemoteBackgroundService.setRemoteAudio(enabled)
                                "setRemoteLocation" -> RemoteBackgroundService.setRemoteLocation(enabled)
                            }
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            cache.put(ENGINE_ID, engine)
        }
    }

}
