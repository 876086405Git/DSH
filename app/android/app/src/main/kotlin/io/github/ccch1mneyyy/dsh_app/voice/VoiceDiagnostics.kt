package io.github.ccch1mneyyy.dsh_app.voice

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.companion.CompanionAssistant
import io.github.ccch1mneyyy.dsh_app.companion.CompanionAssistantRecognitionService
import org.json.JSONArray
import org.json.JSONObject

/** Bounded, content-free observations, persisted independently of the engine process. */
object VoiceDiagnostics {
    private const val PREFS = "voice_recognition_health"
    private const val FAILED_ENVIRONMENT = "failed_environment"
    private const val FAILURES = "recent_failures"
    private val gate = Any()

    @Suppress("DEPRECATION")
    fun environment(context: Context): VoiceEnvironment {
        // VOICE_RECOGNITION_SERVICE is not part of the public Settings.Secure constants.
        val default = runCatching {
            Settings.Secure.getString(context.contentResolver, "voice_recognition_service")
                ?.let(ComponentName::unflattenFromString)
        }.getOrNull()
        val companion = ComponentName(context, CompanionAssistantRecognitionService::class.java)
        val component = if (default == companion) CompanionAssistant.systemRecognizer(context) else default
        val pkg = component?.let { runCatching { context.packageManager.getPackageInfo(it.packageName, 0) }.getOrNull() }
        return VoiceEnvironment(
            sdk = Build.VERSION.SDK_INT,
            osBuild = Build.FINGERPRINT,
            service = component?.flattenToString(),
            servicePackage = component?.packageName,
            serviceVersion = pkg?.let { if (Build.VERSION.SDK_INT >= 28) it.longVersionCode else it.versionCode.toLong() },
            serviceUpdatedAt = pkg?.lastUpdateTime,
            // The room's compatibility service delegates recognition. Its registration alone
            // should not make dictation look available on a phone without a recognizer.
            recognizerAvailable = runCatching {
                when (default) {
                    companion -> component != null
                    null -> context.packageManager.queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
                        .any { ComponentName(it.serviceInfo.packageName, it.serviceInfo.name) != companion }
                    else -> SpeechRecognizer.isRecognitionAvailable(context)
                }
            }.getOrDefault(false),
            // Both this query and the on-device factory were introduced in API 31, not 33.
            onDeviceAvailable = if (Build.VERSION.SDK_INT >= 31) {
                runCatching { SpeechRecognizer.isOnDeviceRecognitionAvailable(context) }.getOrNull()
            } else null,
        )
    }

    fun unreliable(context: Context, environment: VoiceEnvironment): Boolean = runCatching {
        VoicePolicy.isUnreliable(environment, context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(FAILED_ENVIRONMENT, null))
    }.getOrDefault(false)

    fun success(context: Context, environment: VoiceEnvironment) = runCatching { synchronized(gate) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (VoicePolicy.isUnreliable(environment, prefs.getString(FAILED_ENVIRONMENT, null))) {
            prefs.edit().remove(FAILED_ENVIRONMENT).apply()
        }
    } }

    fun failure(context: Context, environment: VoiceEnvironment, code: Int, stage: String, error: Throwable? = null) = runCatching { synchronized(gate) {
        val fields = VoicePolicy.failureFields(environment, code, stage, System.currentTimeMillis(), error?.javaClass?.simpleName)
        val record = JSONObject(fields).toString()
        Log.w("VoicePlugin", record)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val prior = records(context).takeLast(VoicePolicy.MAX_FAILURES - 1)
        val edit = prefs.edit().putString(FAILURES, JSONArray(prior + fields).toString())
        if (stage != "record" && VoicePolicy.serviceFailure(code)) {
            environment.identity?.let { edit.putString(FAILED_ENVIRONMENT, it) }
        }
        edit.apply()
    } }.onFailure {
        // Diagnostics must not suppress the original platform result. No exception message.
        Log.w("VoicePlugin", "diagnosticsUnavailable code=$code stage=${stage.take(16)}")
    }

    @Suppress("DEPRECATION")
    fun snapshot(context: Context): Map<String, Any?> {
        val environment = environment(context)
        val services = runCatching {
            context.packageManager.queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
                .mapNotNull { it.serviceInfo?.let { info -> ComponentName(info.packageName, info.name).flattenToString().take(256) } }
                .distinct().sorted().take(16)
        }.getOrDefault(emptyList())
        return environment.diagnosticFields() + mapOf(
            "systemUnreliable" to unreliable(context, environment),
            "visibleServices" to services,
            "recentFailures" to records(context),
            "onDeviceFactoryProbed" to false,
        )
    }

    private fun records(context: Context): List<Map<String, Any?>> {
        val raw = runCatching { context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(FAILURES, null) }.getOrNull() ?: return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val numbers = setOf("sdk", "serviceVersion", "serviceUpdatedAt", "at", "code")
        val booleans = setOf("recognizerAvailable", "onDeviceFactoryApiAvailable", "onDeviceAvailable")
        val strings = setOf("defaultService", "servicePackage", "environmentId", "name", "stage", "exceptionType")
        return (maxOf(0, array.length() - VoicePolicy.MAX_FAILURES) until array.length()).mapNotNull { i ->
            val row = array.optJSONObject(i) ?: return@mapNotNull null
            buildMap {
                for (key in numbers) (row.opt(key) as? Number)?.let { put(key, it.toLong()) }
                for (key in booleans) (row.opt(key) as? Boolean)?.let { put(key, it) }
                for (key in strings) (row.opt(key) as? String)?.let { put(key, it.take(256)) }
            }
        }
    }
}
