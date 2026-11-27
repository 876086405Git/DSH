package io.github.ccch1mneyyy.dsh_app.runtime

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.Handler
import android.os.Looper
import io.github.ccch1mneyyy.dsh_app.phone.DiagnosticsTool
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import android.provider.Settings
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Flutter bridge for the local runtime: MethodChannel `dsh/runtime`, EventChannel `dsh/runtime/events`. */
class RuntimePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var controller: RuntimeController
    private lateinit var appContext: android.content.Context
    private var sink: RuntimeController.EventSink? = null
    private var activity: ActivityPluginBinding? = null
    private var pendingStorageResult: MethodChannel.Result? = null
    private var pendingLocationResult: (() -> Unit)? = null
    private var remoteCoarseRequested = false
    private val protection get() = AndroidBackgroundProtection.get(appContext)
    private var managedSkillOwner: ManagedSkillOwner? = null
    @Volatile private var diagnosticsAttached = false
    private val diagnosticsRefresh: () -> Boolean = { refreshDiagnostics() }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        controller = RuntimeController.get(binding.applicationContext)
        managedSkillOwner = controller.attachManagedSkillOwner()
        methods = MethodChannel(binding.binaryMessenger, "dsh/runtime").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dsh/runtime/events").also { it.setStreamHandler(this) }
        diagnosticsAttached = true
        controller.attachDiagnosticsRefresh(diagnosticsRefresh)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        diagnosticsAttached = false
        controller.detachDiagnosticsRefresh(diagnosticsRefresh)
        managedSkillOwner?.let { owner ->
            controller.detachManagedSkillOwner(owner)
        }
        managedSkillOwner = null
        protection.setTurnRunning(false)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink?.let { controller.removeSink(it) }
        sink = null
    }

    /** Called only by a bridge worker; Flutter remains free to collect and publish on main. */
    private fun refreshDiagnostics(): Boolean {
        if (!diagnosticsAttached || Looper.myLooper() == Looper.getMainLooper()) return false
        val done = CountDownLatch(1)
        val success = AtomicBoolean(false)
        Handler(Looper.getMainLooper()).post {
            if (!diagnosticsAttached) done.countDown()
            else try {
                methods.invokeMethod("refreshDiagnostics", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        success.set(diagnosticsAttached && result == true)
                        done.countDown()
                    }
                    override fun error(code: String, message: String?, details: Any?) { done.countDown() }
                    override fun notImplemented() { done.countDown() }
                })
            } catch (_: RuntimeException) { done.countDown() }
        }
        if (!done.await(15, TimeUnit.SECONDS)) throw DiagnosticsTool.Failure("diagnostics_timeout")
        return success.get()
    }

    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
        finishLocationRequest()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(controller.status())
            "publishDiagnostics" -> {
                val markdown = call.argument<String>("markdown")
                val manual = call.argument<Any?>("manual") == true
                result.success(if (markdown == null || markdown.length > 256 * 1024) null else controller.publishDiagnostics(markdown, manual = manual,
                    collectedAt = call.argument<Any?>("collectedAt"), sections = call.argument<Any?>("sections")))
            }
            "installManagedSkill" -> {
                val owner = managedSkillOwner
                if (owner == null) result.success(mapOf("result" to null, "current" to false, "reason" to "stale"))
                else controller.installManagedSkill(owner, call.arguments, result::success)
            }
            "cancelManagedSkill" -> {
                val requestId = (call.arguments as? Map<*, *>)?.get("requestId") as? String
                if (requestId != null && requestId.length in 1..200) {
                    managedSkillOwner?.let { controller.cancelManagedSkill(it, requestId) }
                }
                result.success(null)
            }
            "install" -> {
                // A second call must not end the running unpack's foreground service.
                if (controller.phase == RuntimeController.Phase.INSTALLING) return result.error("install_busy", null, null)
                val intent = Intent(appContext, DshService::class.java).setAction(DshService.ACTION_INSTALL)
                    .putExtra("upgrade", controller.status()["installedVersion"] != null)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) appContext.startForegroundService(intent)
                else appContext.startService(intent)
                controller.install(dropKept = call.argument<Boolean>("dropKept") == true) { error ->
                    appContext.startService(
                        Intent(appContext, DshService::class.java).setAction(DshService.ACTION_INSTALL_DONE)
                            .putExtra(DshService.EXTRA_INSTALL_OK, error == null),
                    )
                    if (error == null) result.success(null) else result.error("install_failed", error.message, null)
                }
            }
            "start" -> {
                val env = (call.argument<Map<String, Any?>>("env") ?: emptyMap())
                    .mapNotNull { (k, v) -> v?.toString()?.let { k to it } }.toMap()
                controller.start(
                    env,
                    phoneStorage = call.argument<Boolean>("phoneStorage") == true,
                    mode = call.argument<String>("mode"),
                    visualReplies = call.argument<Boolean>("visualReplies") != false,
                )
                result.success(null)
            }
            "stop" -> {
                controller.stop()
                result.success(null)
            }
            "getLogs" -> result.success(controller.recentLogs(call.argument<Int>("lines") ?: 500))
            "getLogSnapshot" -> result.success(controller.logSnapshot((call.argument<Int>("lines") ?: 300).coerceIn(0, 2000)))
            "reset" -> controller.reset(ResetKeep.fromWire(call.argument<List<String>>("keep").orEmpty())) { error ->
                if (error == null) result.success(null) else result.error("reset_failed", error.message, null)
            }
            "lastKnownGood" -> controller.lastKnownGoodStatus { result.success(it) }
            "restoreLastKnownGood" -> controller.restoreLastKnownGood { plan, error ->
                if (error == null) result.success(plan) else result.error(if (error is RuntimeNotStoppedException) "runtime_not_stopped" else "restore_failed", error.message, null)
            }
            "safePreflight" -> controller.safePreflight { result.success(it) }
            "moveAside" -> controller.moveAside(call.argument<List<String>>("paths") ?: emptyList()) { moved, error ->
                if (error == null) result.success(moved) else result.error(if (error is RuntimeNotStoppedException) "runtime_not_stopped" else "move_failed", error.message, null)
            }
            "clearFailure" -> {
                controller.clearFailure()
                result.success(null)
            }
            "setAutoSafe" -> {
                controller.setAutoSafe(call.argument<Boolean>("enabled") != false)
                result.success(null)
            }
            "setWorkspaceRecovery" -> {
                val enabled = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
                if (enabled == null) result.error("workspace_recovery_invalid", "enabled must be a boolean", null)
                else controller.setWorkspaceRecovery(enabled) { error ->
                    if (error == null) result.success(null)
                    else result.error(
                        if (error is RuntimeNotStoppedException) "runtime_not_stopped" else "workspace_recovery_save_failed",
                        error.message,
                        null,
                    )
                }
            }
            "setDirectEngine" -> {
                try {
                    controller.setDirectEngine(call.argument<Boolean>("enabled") == true)
                    result.success(null)
                } catch (error: IllegalStateException) {
                    result.error("launch_method_unavailable", error.message, null)
                }
            }
            "setTawcEngine" -> {
                try {
                    controller.setTawcEngine(call.argument<Boolean>("enabled") == true)
                    result.success(null)
                } catch (error: IllegalStateException) {
                    result.error("launch_method_unavailable", error.message, null)
                }
            }
            "failureLog" -> result.success(controller.failureLog())
            "batteryExempt" -> {
                val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(pm.isIgnoringBatteryOptimizations(appContext.packageName))
            }
            "requestBatteryExempt" -> result.success(requestBatteryExempt())
            "backgroundProtection" -> result.success(protection.status())
            "setBackgroundProtection" -> setBackgroundProtection(call, result)
            "openBackgroundProtectionSettings" -> result.success(openBackgroundProtectionSettings())
            "turnRunning" -> {
                protection.setTurnRunning(call.argument<Boolean>("running") == true)
                result.success(null)
            }
            "backgroundSettings" -> result.success(
                mapOf(
                    "vendor" to VendorSettings.vendorOf(Build.MANUFACTURER, Build.BRAND),
                    "label" to appContext.applicationInfo.loadLabel(appContext.packageManager).toString(),
                ),
            )
            "openBackgroundSettings" -> result.success(openVendorSettings(VendorSettings.Switch.BACKGROUND))
            "openVendorSettings" -> result.success(
                openVendorSettings(VendorSettings.Switch.parse(call.argument<String>("switch")) ?: VendorSettings.Switch.BACKGROUND),
            )
            "networkMetered" -> result.success(networkMetered())
            "voiceModelLine" -> {
                DshService.setVoiceLine(appContext, call.argument<String>("text"), call.argument<Int>("progress"))
                result.success(null)
            }
            "storageStatus" -> result.success(PhoneStorage.status(appContext))
            "requestStorage" -> requestStorage(result)
            "openAllFilesAccess" -> {
                val intent = PhoneStorage.allFilesAccessIntent(appContext)
                result.success(intent != null && runCatching { appContext.startActivity(intent) }.isSuccess)
            }
            else -> result.notImplemented()
        }
    }

    /** The system's "ignore battery optimizations" dialog, else the closest settings page that opens. */
    private fun requestBatteryExempt(): Boolean {
        val packageUri = Uri.parse("package:${appContext.packageName}")
        val host = activity?.activity
        for (intent in listOf(
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri),
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri),
        )) {
            val started = runCatching {
                if (host != null) host.startActivity(intent)
                else appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.isSuccess
            if (started) return true
        }
        return false
    }

    /**
     * The vendor's own page for [switch] when one resolves, else this app's system details page:
     * `vendor`, `details`, or null when neither opened.
     */
    private fun openVendorSettings(switch: VendorSettings.Switch): String? {
        val pm = appContext.packageManager
        val packageName = appContext.packageName
        val host = activity?.activity
        fun launch(intent: Intent): Boolean = runCatching {
            if (host != null) host.startActivity(intent)
            else appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.isSuccess
        val vendor = VendorSettings.vendorOf(Build.MANUFACTURER, Build.BRAND)
        for (page in VendorSettings.pages(vendor, switch)) {
            val cls = page.cls
            val intent = if (cls != null) {
                Intent().setComponent(ComponentName(page.pkg, cls))
            } else {
                Intent(page.action ?: continue).setPackage(page.pkg)
            }
            page.packageExtra?.let { intent.putExtra(it, packageName) }
            page.labelExtra?.let { intent.putExtra(it, appContext.applicationInfo.loadLabel(pm).toString()) }
            val info = runCatching { intent.resolveActivityInfo(pm, 0) }.getOrNull()
            if (info?.exported != true) continue
            if (cls == null) intent.setClassName(info.packageName, info.name)
            if (launch(intent)) return "vendor"
        }
        val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
        return if (launch(details)) "details" else null
    }

    /** Whether the active network is metered (mobile data, a metered hotspot); null when unknown. */
    private fun networkMetered(): Boolean? = runCatching {
        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        if (cm.activeNetwork == null) null else cm.isActiveNetworkMetered
    }.getOrNull()

    /** Asks for READ/WRITE_EXTERNAL_STORAGE; answers with the resulting status map. */
    private fun requestStorage(result: MethodChannel.Result) {
        if (PhoneStorage.isGranted(appContext)) return result.success(PhoneStorage.status(appContext))
        val host: Activity = activity?.activity ?: return result.error("no_activity", "no foreground activity", null)
        pendingStorageResult?.success(PhoneStorage.status(appContext))
        pendingStorageResult = result
        host.requestPermissions(
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
            STORAGE_REQUEST,
        )
    }

    private fun setBackgroundProtection(call: MethodCall, result: MethodChannel.Result) {
        val locationEnabled = call.argument<Boolean>("locationEnabled")
        protection.setEnabled(call.argument<Boolean>("audioEnabled"), locationEnabled)
        val host = activity?.activity
        if (locationEnabled != true || protection.hasCoarseLocation() || host == null) {
            result.success(protection.status())
            return
        }
        requestCoarseLocation(host, { result.success(protection.status()) }, { result.error(it, null, null) })
    }

    /** Called by a foreground settings action, never by a preference update or the service. */
    internal fun requestRemoteLocation(result: MethodChannel.Result) {
        val host = activity?.activity ?: return result.success(false)
        if (!MainActivity.inForeground || pendingLocationResult != null) return result.success(false)

        fun isReady() = protection.hasBackgroundLocation() && protection.locationEnabledInSystem
        val hasCoarse = protection.hasCoarseLocation()
        val hasBackground = protection.hasBackgroundLocation()
        if (isReady()) return result.success(true)
        if (hasCoarse || remoteCoarseRequested && !host.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION)) {
            // Launching settings does not mean permission has already been granted.
            openLocationSettings(host, locationDisabled = hasBackground)
            return result.success(false)
        }
        requestCoarseLocation(host, {
            remoteCoarseRequested = true
            result.success(isReady())
        }, { result.success(false) })
    }

    private fun requestCoarseLocation(host: Activity, onFinished: () -> Unit, onError: (String) -> Unit) {
        // With target 28, the system may offer background access as part of the coarse request.
        // Otherwise the user can grant it separately in the app's system settings.
        if (pendingLocationResult != null) return onError("location_request_pending")
        pendingLocationResult = onFinished
        try {
            host.requestPermissions(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION), LOCATION_REQUEST)
        } catch (_: RuntimeException) {
            pendingLocationResult = null
            onError("location_request_failed")
        }
    }

    private fun finishLocationRequest() {
        val pending = pendingLocationResult ?: return
        pendingLocationResult = null
        protection.refresh()
        pending()
    }

    private fun openBackgroundProtectionSettings(): Boolean {
        val host = activity?.activity ?: return false
        return openLocationSettings(host, protection.status()["error"] == AndroidBackgroundProtection.LOCATION_DISABLED)
    }

    private fun openLocationSettings(host: Activity, locationDisabled: Boolean): Boolean {
        val intent = if (locationDisabled) {
            Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
        } else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${appContext.packageName}"))
        return runCatching { host.startActivity(intent) }.isSuccess
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode == LOCATION_REQUEST) {
            finishLocationRequest()
            return true
        }
        if (requestCode != STORAGE_REQUEST) return false
        pendingStorageResult?.success(PhoneStorage.status(appContext))
        pendingStorageResult = null
        return true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink?.let { controller.removeSink(it) }
        val s = RuntimeController.EventSink { events.success(it) }
        sink = s
        controller.addSink(s)
        events.success(mapOf("type" to "status", "status" to controller.status()))
    }

    override fun onCancel(arguments: Any?) {
        sink?.let { controller.removeSink(it) }
        sink = null
    }

    companion object {
        private const val STORAGE_REQUEST = 0x5d5
        private const val LOCATION_REQUEST = 0x5d9
    }
}
