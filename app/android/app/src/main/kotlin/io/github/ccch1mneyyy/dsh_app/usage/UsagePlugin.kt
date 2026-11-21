package io.github.ccch1mneyyy.dsh_app.usage

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.update.ApkInstaller
import java.io.File
import java.util.Locale

/**
 * What anonymous usage statistics say about the phone: MethodChannel `dsh/usage` (see
 * lib/usage/usage_net.dart).
 *
 * - `device` → `{versionName, versionCode, sdk, abi, maker, model, rom}`.
 *
 * Only facts shared by every phone of a kind: the model (`Build.MODEL`) and the maker's system
 * with its version, never a serial, the Android ID, an advertising ID or a build fingerprint.
 */
class UsagePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var methods: MethodChannel? = null
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        methods = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "device" -> result.success(device())
            "abnormalExits" -> {
                if (Build.VERSION.SDK_INT < 30) {
                    result.success(null)
                    return
                }
                val since = (call.arguments as? Number)?.toLong() ?: Long.MAX_VALUE
                val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                try {
                    val rows = manager.getHistoricalProcessExitReasons(context.packageName, 0, 32)
                        .filter { it.packageUid == context.applicationInfo.uid && it.timestamp > since }
                        .mapNotNull { exit ->
                            val kind = when (exit.reason) {
                                ApplicationExitInfo.REASON_ANR -> "anr"
                                ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash"
                                else -> return@mapNotNull null
                            }
                            listOf(exit.timestamp, kind)
                        }
                    result.success(rows)
                } catch (_: RuntimeException) {
                    result.error("exit_info_unavailable", "Exit information unavailable", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun device(): Map<String, Any?> {
        val pkg = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
        return mapOf(
            "versionName" to pkg?.versionName,
            "versionCode" to pkg?.let { ApkInstaller.versionCodeOf(it) },
            "sdk" to Build.VERSION.SDK_INT,
            "abi" to UsageDevice.abiOf(context.applicationInfo.nativeLibraryDir?.let { File(it).name }, Build.SUPPORTED_ABIS.toList()),
            "maker" to UsageDevice.makerOf(Build.MANUFACTURER),
            "model" to UsageDevice.makerOf(Build.MODEL),
            "rom" to UsageDevice.romOf(::systemProperty),
        )
    }

    companion object {
        const val CHANNEL = "dsh/usage"

        /** A system property, or null; android.os.SystemProperties isn't public API. */
        private fun systemProperty(name: String): String? = runCatching {
            Class.forName("android.os.SystemProperties").getMethod("get", String::class.java).invoke(null, name) as? String
        }.getOrNull()?.trim()?.takeIf { it.isNotEmpty() }
    }
}

/** The pieces of [UsagePlugin.device] that are pure functions. */
object UsageDevice {
    /** The installer's library folder names (`lib/arm64`) by Android ABI name. */
    private val ABIS = mapOf("arm64" to "arm64-v8a", "arm" to "armeabi-v7a", "x86_64" to "x86_64", "x86" to "x86")

    /**
     * The ABI this APK runs as, in Android's naming (`arm64-v8a`): from its native library
     * folder, else the phone's first supported ABI. Empty when neither says.
     */
    fun abiOf(libraryDir: String?, supported: List<String>): String =
        ABIS[libraryDir] ?: supported.firstOrNull()?.takeIf { it.isNotBlank() } ?: ""

    /**
     * `Build.MANUFACTURER` the way the share host takes it: lower case, ASCII letters, digits,
     * spaces and `. _ -` only, starting with a letter or digit, 32 at most (`vivo`); `unknown`
     * when nothing is left. lib/usage/usage_ledger.dart `usageMaker` does the same.
     */
    fun makerOf(manufacturer: String?): String {
        val kept = manufacturer.orEmpty().lowercase(Locale.ROOT)
            .replace(Regex("[^a-z0-9 ._-]"), "")
            .replaceFirst(Regex("^[^a-z0-9]+"), "")
            .take(32)
            .trim()
        return kept.ifEmpty { "unknown" }
    }

    /**
     * The maker's system and its version from [property] (a system property by name), the way
     * [makerOf] cleans text: `originos 5.0`, `hyperos os2.0`, `coloros v15.0.0`. `android` when
     * none of the known ones is set. OnePlus phones report ColorOS's property under OxygenOS too.
     */
    fun romOf(property: (String) -> String?): String {
        fun named(name: String, key: String) = property(key)?.let { "$name $it" }
        val vivo = property("ro.vivo.os.name")?.let { name -> "$name ${property("ro.vivo.os.version").orEmpty()}" }
        val found = named("harmonyos", "hw_sc.build.platform.version")
            ?: named("hyperos", "ro.mi.os.version.name")
            ?: named("miui", "ro.miui.ui.version.name")
            ?: vivo
            ?: named("realme ui", "ro.build.version.realmeui")
            ?: named("coloros", "ro.build.version.oplusrom")
            ?: named("coloros", "ro.build.version.opporom")
            ?: named("magicos", "ro.build.version.magic")
            ?: named("emui", "ro.build.version.emui")
            ?: named("oneui", "ro.build.version.oneui")
            ?: return "android"
        return makerOf(found)
    }
}
