package io.github.ccch1mneyyy.dsh_app.companion

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.ccch1mneyyy.dsh_app.notify.ChatNotifier

/** Channel ownership follows the cached engine, not an Activity. */
class CompanionAlwaysOnPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var ready = false
    private var activity: ActivityPluginBinding? = null
    private data class NotificationRequest(val code: Int, val epoch: Long,
        val results: MutableList<MethodChannel.Result>)
    private var notificationRequest: NotificationRequest? = null
    private var batteryLow: Boolean? = null
    private var powerSave = false
    private var powerReceiverRegistered = false
    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (current !== this@CompanionAlwaysOnPlugin) return
            val beforeLow = batteryLow
            val beforeSave = powerSave
            readPower(intent)
            if (batteryLow != beforeLow || powerSave != beforeSave) statusChanged()
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        batteryLow = null
        current = this
        channel = MethodChannel(binding.binaryMessenger, "dsh/companion/always_on")
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ready" -> {
                        ready = true
                        startIfAvailable()
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
                            enableWithNotification(result)
                        } else {
                            pending.clear()
                            CompanionConversationNotification.clear(context)
                            context.stopService(Intent(context, CompanionAlwaysOnService::class.java))
                            finishNotificationRequest()
                            result.success(status())
                            statusChanged()
                        }
                    }
                    "update" -> {
                        if (call.hasArgument("noticeEpoch")) {
                            val expected = call.argument<Any>("noticeEpoch")
                            if ((expected !is Long && expected !is Int) ||
                                !CompanionNotices.get(context).allows((expected as Number).toLong())) {
                                result.success(false)
                                return@setMethodCallHandler
                            }
                        }
                        result.success(CompanionConversationNotification.update(context,
                            call.argument<Number>("epoch")!!.toLong(), call.argument<String>("id")!!,
                            call.argument<String>("text")!!, call.argument<String>("name").orEmpty(),
                            call.argument<Boolean>("user") == true, call.argument<Boolean>("quiet") != false))
                    }
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
        // All four actions are system broadcasts; no exported flag or new
        // permission/manifest receiver is needed. The returned sticky Intent
        // supplies the initial low-battery state when the API exposes it.
        val sticky = context.registerReceiver(powerReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_BATTERY_LOW)
            addAction(Intent.ACTION_BATTERY_OKAY)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        })
        powerReceiverRegistered = true
        readPower(sticky)
    }

    /** Only the explicit switch may ask. Restoring a lease never opens a prompt. */
    private fun enableWithNotification(result: MethodChannel.Result) {
        notificationRequest?.let {
            it.results.add(result)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            val host = activity?.activity
            if (host != null && !host.isFinishing && !host.isDestroyed) {
                val request = NotificationRequest(nextNotificationRequestCode++,
                    CompanionAlwaysOnState.read(context).epoch, mutableListOf(result))
                notificationRequest = request
                statusChanged()
                // target 28 is required by the rootfs. Its notification
                // permission cannot be requested by this app at runtime.
                val notifier = ChatNotifier(context)
                for (intent in listOf(notifier.settingsIntent(null), notifier.detailsIntent())) {
                    try {
                        host.startActivityForResult(intent, request.code)
                        failure = null
                        return
                    } catch (error: Exception) { failure = error.javaClass.simpleName }
                }
                finishNotificationRequest()
                return
            }
        } else {
            startIfAvailable(disableOnFailure = true)
        }
        result.success(status())
        statusChanged()
    }

    private fun startIfAvailable(disableOnFailure: Boolean = false) {
        if (current !== this || notificationRequest != null ||
            !CompanionAlwaysOnState.read(context).enabled || CompanionAlwaysOnService.running ||
            !CompanionConversationNotification.available(context)) return
        try { CompanionAlwaysOnService.start(context) }
        catch (error: Exception) {
            if (disableOnFailure) CompanionAlwaysOnState.set(context, false)
            failure = error.javaClass.simpleName
        }
    }

    private fun finishNotificationRequest(continueEnable: Boolean = false) {
        val request = notificationRequest ?: return
        notificationRequest = null
        val state = CompanionAlwaysOnState.read(context)
        if (continueEnable && current === this && activity != null && state.enabled && state.epoch == request.epoch) {
            startIfAvailable(disableOnFailure = true)
        }
        val value = status()
        request.results.forEach { it.success(value) }
        statusChanged()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }

    private fun detachActivity() {
        activity?.removeActivityResultListener(this)
        activity = null
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        detachActivity()
        finishNotificationRequest()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val request = notificationRequest ?: return false
        if (requestCode != request.code) return false
        // Settings has no grant result. Returning only permits a fresh read of
        // available(); neither opening the page nor RESULT_OK is authorization.
        finishNotificationRequest(continueEnable = true)
        return true
    }

    private fun readPower(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BATTERY_LOW -> batteryLow = true
            Intent.ACTION_BATTERY_OKAY -> batteryLow = false
            Intent.ACTION_BATTERY_CHANGED -> {
                if (intent != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && intent.hasExtra(BatteryManager.EXTRA_BATTERY_LOW)) {
                    batteryLow = intent.getBooleanExtra(BatteryManager.EXTRA_BATTERY_LOW, false)
                }
            }
        }
        powerSave = (context.getSystemService(Context.POWER_SERVICE) as PowerManager).isPowerSaveMode
    }

    private fun status(): Map<String, Any?> {
        readPower(null)
        val state = CompanionAlwaysOnState.read(context)
        return mapOf("enabled" to state.enabled, "epoch" to state.epoch,
            "running" to CompanionAlwaysOnService.running,
            "batteryLow" to batteryLow, "powerSave" to powerSave,
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
        detachActivity()
        finishNotificationRequest()
        ready = false
        if (powerReceiverRegistered) {
            context.unregisterReceiver(powerReceiver)
            powerReceiverRegistered = false
        }
        channel.setMethodCallHandler(null)
        if (current === this) current = null
    }

    companion object {
        // A retired Activity's result must not complete a later enable request.
        private var nextNotificationRequestCode = 0x434f0000
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
