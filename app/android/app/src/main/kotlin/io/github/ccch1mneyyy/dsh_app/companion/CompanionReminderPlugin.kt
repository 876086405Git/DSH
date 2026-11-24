package io.github.ccch1mneyyy.dsh_app.companion

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

/** 不打开 memory.sqlite，也不把唤醒广播的返回当作提醒已设好。 */
class CompanionReminderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dsh/companion_reminders",
            StandardMethodCodec.INSTANCE, binding.binaryMessenger.makeBackgroundTaskQueue())
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "clock" -> result.success(CompanionReminderTime.observe())
                "resolve" -> result.success(CompanionReminderTime.resolve(
                    call.argument<String>("localDate")!!,
                    call.argument<String>("localTime")!!,
                    call.argument<String>("zoneId")!!,
                    call.argument<Int>("selectedOffsetSeconds"),
                ))
                "capabilities" -> result.success(CompanionReminderPlatform.capabilities(context))
                "recover" -> result.success(mapOf("recoveryQueued" to CompanionReminderJob.schedule(context)))
                "wake" -> {
                    val taskId = call.argument<String>("taskId")
                    require(!taskId.isNullOrEmpty()) { "A reminder task is required" }
                    // Persist a native recovery opportunity before the short direct wake.
                    // Scheduling itself is not a task execution receipt.
                    CompanionReminderJob.schedule(context)
                    val intent = Intent(context, CompanionReminderReceiver::class.java)
                        .setAction(CompanionReminderReceiver.ACTION_WAKE)
                        .putExtra(CompanionReminderReceiver.EXTRA_TASK, taskId)
                    context.sendOrderedBroadcast(intent, null, object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) {
                            result.success(mapOf("wakeCompleted" to (resultCode == Activity.RESULT_OK)))
                        }
                    }, Handler(Looper.getMainLooper()), Activity.RESULT_CANCELED, null, null)
                }
                "openSettings" -> {
                    val intent = when (call.argument<String>("kind")) {
                        "notifications" -> Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            .putExtra(Settings.EXTRA_CHANNEL_ID,
                                io.github.ccch1mneyyy.dsh_app.phone.SystemActions.CHANNEL_NOTIFY)
                        else -> throw IllegalArgumentException("Unknown reminder settings")
                    }
                    context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("reminder_platform", error.message, null)
        }
    }
}
