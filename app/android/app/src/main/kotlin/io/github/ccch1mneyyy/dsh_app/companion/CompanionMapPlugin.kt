package io.github.ccch1mneyyy.dsh_app.companion

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.phone.AppVisibility

/** A finite foreground handoff; no service, recovery timer, screen access, or location request. */
class CompanionMapPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    Application.ActivityLifecycleCallbacks {
    private lateinit var context: Context
    private lateinit var application: Application
    private lateinit var channel: MethodChannel
    private lateinit var platform: CompanionMapPlatform
    private val scopes = CompanionMapScopes()
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        application = context.applicationContext as Application
        AppVisibility.register(application)
        application.registerActivityLifecycleCallbacks(this)
        platform = CompanionMapPlatform(context)
        // The default queue runs on the UI thread. Scope, lifecycle, and startActivity share it.
        channel = MethodChannel(binding.binaryMessenger, "dsh/companion_maps")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        application.unregisterActivityLifecycleCallbacks(this)
        scopes.clear(); activity = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        scopes.clear(); activity = binding.activity
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onDetachedFromActivity() { scopes.clear(); activity = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            check(Looper.myLooper() == Looper.getMainLooper())
            when (call.method) {
                "capabilities" -> result.success(mapOf("executorId" to CompanionReminderPlatform.executorId(context)))
                "targets" -> result.success(platform.targets(requireNotNull(call.argument<String>("address"))))
                "openScope" -> {
                    val attached = requireNotNull(activity) { "The original page is not in the foreground" }
                    check(platform.foreground(attached)) { "The original page is not in the foreground" }
                    val owner = scopes.open(requireNotNull(call.argument<String>("sourceSessionId")))
                    try {
                        CompanionMapLedger.open(context).use { it.openScope(owner.id, owner.sourceSessionId) }
                    } catch (error: Exception) { scopes.close(owner.id); throw error }
                    result.success(mapOf("scopeId" to owner.id))
                }
                "closeScope" -> {
                    scopes.close(requireNotNull(call.argument<String>("scopeId")))
                    result.success(null)
                }
                "handoff" -> {
                    val id = requireNotNull(call.argument<String>("taskId"))
                    val revision = requireNotNull(call.argument<Number>("taskRev")).toLong()
                    val scopeId = requireNotNull(call.argument<String>("scopeId"))
                    require(id.isNotBlank() && revision > 0 && scopeId.isNotBlank())
                    handoff(CompanionMapKey(id, revision), scopeId)
                    // Only the SQLite result is a receipt. This acknowledgement is never done.
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("map_platform", error.message, null) }
    }

    private fun handoff(key: CompanionMapKey, scopeId: String) {
        val attached = activity
        fun unavailable(ledger: CompanionMapLedger, sourceSessionId: String? = null): String? {
            val owner = scopes.current(scopeId) ?: return "map_scope_closed"
            if (sourceSessionId != null && owner.sourceSessionId != sourceSessionId) return "map_room_changed"
            // Dart closes this row synchronously before returning from page invalidation.
            // Its write serializes with the final dispatch transaction, independent of channel FIFO.
            if (!ledger.scopeOpen(owner.id, owner.sourceSessionId)) return "map_scope_closed"
            if (attached == null || activity !== attached || !platform.foreground(attached))
                return "map_foreground_unavailable"
            return null
        }
        try {
            val executorId = CompanionReminderPlatform.executorId(context)
            CompanionMapLedger.open(context).use { ledger ->
                val claim = ledger.claim(key, executorId, System.currentTimeMillis()) {
                    unavailable(ledger, it.sourceSessionId)
                } ?: return@use
                ledger.dispatch(claim, System::currentTimeMillis, { unavailable(ledger, it.sourceSessionId) }) { argument ->
                    platform.dispatch(requireNotNull(attached), argument) { unavailable(ledger) }
                }
            }
        } finally {
            // A fresh explicit action needs a new scope, including a known-safe blocked attempt.
            scopes.close(scopeId)
        }
    }

    override fun onActivityPaused(activity: Activity) { if (activity === this.activity) scopes.clear() }
    override fun onActivityDestroyed(activity: Activity) { if (activity === this.activity) scopes.clear() }
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
}
