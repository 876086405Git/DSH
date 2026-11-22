package io.github.ccch1mneyyy.dsh_app.companion

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Channel ownership follows the cached engine, not an Activity. */
class CompanionAlwaysOnPlugin : FlutterPlugin {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var ready = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        current = this
        channel = MethodChannel(binding.binaryMessenger, "dsh/companion/always_on")
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ready" -> {
                        ready = true
                        if (CompanionAlwaysOnState.read(context).enabled && !CompanionAlwaysOnService.running) {
                            try { CompanionAlwaysOnService.start(context) } catch (error: Exception) { failure = error.javaClass.simpleName }
                        }
                        result.success(status())
                        Handler(Looper.getMainLooper()).post { flush() }
                    }
                    "status" -> result.success(status())
                    "failure" -> {
                        failure = call.argument<String>("code")
                        result.success(status())
                        statusChanged()
                    }
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        CompanionAlwaysOnState.set(context, enabled)
                        failure = null
                        if (enabled) {
                            try { CompanionAlwaysOnService.start(context) }
                            catch (error: Exception) {
                                CompanionAlwaysOnState.set(context, false)
                                failure = error.javaClass.simpleName
                            }
                        } else {
                            pending.clear()
                            CompanionConversationNotification.clear(context)
                            context.stopService(Intent(context, CompanionAlwaysOnService::class.java))
                        }
                        result.success(status())
                        statusChanged()
                    }
                    "update" -> result.success(CompanionConversationNotification.update(context,
                        call.argument<Number>("epoch")!!.toLong(), call.argument<String>("id")!!,
                        call.argument<String>("text")!!, call.argument<String>("name").orEmpty(),
                        call.argument<Boolean>("user") == true, call.argument<Boolean>("quiet") != false))
                    "clear" -> {
                        if (CompanionAlwaysOnState.read(context).epoch == call.argument<Number>("epoch")?.toLong()) {
                            CompanionConversationNotification.clear(context)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("companion_resident_failed", error.message, null)
            }
        }
    }

    private fun status(): Map<String, Any?> {
        val state = CompanionAlwaysOnState.read(context)
        return mapOf("enabled" to state.enabled, "epoch" to state.epoch,
            "running" to CompanionAlwaysOnService.running,
            "notificationAvailable" to CompanionConversationNotification.available(context), "failure" to failure)
    }

    private fun flush() {
        if (!ready) return
        channel.invokeMethod("status", status())
        val state = CompanionAlwaysOnState.read(context)
        while (pending.isNotEmpty()) {
            val input = pending.removeFirst()
            if (state.enabled && input["epoch"] == state.epoch) channel.invokeMethod("reply", input)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ready = false
        channel.setMethodCallHandler(null)
        if (current === this) current = null
    }

    companion object {
        private var current: CompanionAlwaysOnPlugin? = null
        private val pending = ArrayDeque<Map<String, Any>>()
        private val accepted = linkedSetOf<String>()
        var failure: String? = null

        internal fun acceptReply(context: Context, id: String, text: String) {
            val state = CompanionAlwaysOnState.read(context)
            if (!state.enabled || !accepted.add(id)) return
            while (accepted.size > 64) accepted.remove(accepted.first())
            pending.addLast(mapOf("id" to id, "text" to text, "epoch" to state.epoch))
            current?.flush()
        }

        internal fun statusChanged() {
            current?.let { if (it.ready) it.channel.invokeMethod("status", it.status()) }
        }
    }
}
