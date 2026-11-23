package io.github.ccch1mneyyy.dsh_app.companion

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Exposes settings and a pull-based inbox. Signals contain only an epoch, even during engine startup. */
class CompanionNoticesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var notices: CompanionNotices

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        notices = CompanionNotices.get(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "dsh/companion")
        channel.setMethodCallHandler(this)
        notices.signal = { epoch -> channel.invokeMethod("noticeSignal", mapOf("epoch" to epoch)) }
        notices.refreshBinding()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        notices.signal = null
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            val value: Any? = when (call.method) {
                "notices.status" -> notices.status()
                "notices.setEnabled" -> {
                    notices.setEnabled(requireNotNull(call.argument<Boolean>("enabled")))
                    notices.status()
                }
                "notices.setLevel" -> {
                    notices.setLevel(requireNotNull(call.argument<String>("pkg")), requireNotNull(call.argument<String>("level")))
                    notices.status()
                }
                "notices.recentApps" -> notices.recentApps()
                "notices.pending" -> notices.pending()
                "notices.takeBatch" -> notices.take(
                    requireNotNull(call.argument<String>("pkg")), requireNotNull(call.argument<List<String>>("keys")),
                    requireNotNull(call.argument<Number>("epoch")).toLong())
                "notices.record" -> notices.record(requireNotNull(call.argument<Number>("epoch")).toLong(),
                    call.argument<Int>("judged") ?: 0, call.argument<Int>("said") ?: 0)
                else -> return result.notImplemented()
            }
            result.success(value)
        } catch (_: IllegalArgumentException) {
            result.error("invalid_notice_arguments", null, null)
        } catch (error: Exception) {
            result.error("notice_platform_failed", error.javaClass.simpleName, null)
        }
    }
}
