package io.github.ccch1mneyyy.dsh_app.voice

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.ccch1mneyyy.dsh_app.nativemedia.MicArbiter

/**
 * Composer voice input: MethodChannel `dsh/voice` and EventChannel `dsh/voice/events`.
 *
 * Two ways to listen, picked by Dart per recording (the system recognizer in automatic mode;
 * the recorder is also the one-time fallback when that service fails):
 * - `startRecognizer`: the system [SpeechRecognizer] (Google's or the vendor's service) with partial
 *   results; `stop` asks for the final text, which arrives as an event.
 * - `startRecorder`: 16 kHz mono PCM16 for the engine's own recognizer ([WavRecorder]); `stop` returns
 *   the WAV bytes.
 *
 * Methods: capabilities, requestPermission (granted / denied / blocked), openSettings, startRecognizer,
 * startRecorder, stop, cancel. Events (maps with `type`): level (0..1), partial, final, error (code),
 * limit (the recorder hit its length cap), end.
 *
 * Dictation holds the app's one microphone ([MicArbiter]): a plugin listening for speech stops
 * before it starts, and gets it back only through a new tap.
 */
class VoicePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var appContext: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())
    private var activity: ActivityPluginBinding? = null
    private var sink: EventChannel.EventSink? = null

    private var recognizer: SpeechRecognizer? = null
    private var recognizerEnvironment: VoiceEnvironment? = null
    private var recorder: WavRecorder? = null
    private var recognizerMic = 0
    private var recorderMic = 0
    private var generation = 0L
    private var pendingPermission: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "dsh/voice").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dsh/voice/events").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        StreamingPcm.disable()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        releaseAll()
        sink = null
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
        pendingPermission?.success("denied")
        pendingPermission = null
        releaseAll()
    }

    // MethodChannel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> {
                val environment = VoiceDiagnostics.environment(appContext)
                result.success(mapOf(
                    "recognizer" to environment.recognizerAvailable,
                    "recorder" to true,
                    "systemUnreliable" to VoiceDiagnostics.unreliable(appContext, environment),
                    "environmentId" to environment.identity,
                ))
            }
            "requestPermission" -> requestPermission(result)
            // The microphone grant as it stands, without asking.
            "permission" -> result.success(if (hasPermission()) "granted" else "denied")
            "openSettings" -> result.success(openSettings())
            "startRecognizer" -> startRecognizer(call.argument<String>("language"), call.argument<Number>("sessionId")?.toLong() ?: 0, result)
            "startRecorder" -> startRecorder(call.argument<Int>("maxSeconds") ?: 60, call.argument<Number>("sessionId")?.toLong() ?: 0, result)
            "streamingPcm" -> {
                val source = call.argument<String>("source")
                val id = call.argument<Number>("pcmSession")?.toLong() ?: 0
                if (source == null) StreamingPcm.disable(id)
                else if (source == "call" || source == "dictation") {
                    StreamingPcm.enable(source, id) { tap, bytes, valid -> main.post {
                        if (StreamingPcm.current(tap) && valid()) sink?.success(mapOf(
                            "type" to "pcm", "bytes" to bytes, "rate" to 16000,
                            "source" to tap.source, "pcmSession" to tap.id,
                        ))
                    } }
                } else return result.error("pcm-source", "invalid PCM source", null)
                result.success(null)
            }
            "stop" -> stop(result)
            "cancel" -> {
                releaseAll()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean =
        appContext.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) return result.success("granted")
        val host = activity?.activity ?: return result.success("denied")
        if (pendingPermission != null) return result.error("busy", "a permission request is open", null)
        pendingPermission = result
        host.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val host: Activity? = activity?.activity
        result.success(
            when {
                granted -> "granted"
                // Denied with "don't ask again" (or by policy): only Settings can turn it on now.
                host != null && !host.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) ->
                    "blocked"
                else -> "denied"
            },
        )
        return true
    }

    private fun openSettings(): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", appContext.packageName, null))
        val host = activity?.activity
        return runCatching {
            if (host != null) host.startActivity(intent)
            else appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.isSuccess
    }

    // System recognizer

    private fun startRecognizer(language: String?, sessionId: Long, result: MethodChannel.Result) {
        releaseAll()
        val environment = VoiceDiagnostics.environment(appContext)
        if (!hasPermission()) {
            VoiceDiagnostics.failure(appContext, environment, SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS, "start")
            return result.error("permission", "microphone permission required", mapOf("code" to 9))
        }
        val context: Context = activity?.activity ?: appContext
        val outcome = runCatching { SpeechRecognizer.createSpeechRecognizer(context) }
        val created = outcome.getOrNull()
        if (created == null) {
            val error = outcome.exceptionOrNull()
            val code = if (error is SecurityException) 9 else 5
            VoiceDiagnostics.failure(appContext, environment, code, "start", error)
            return result.error("recognizer", "could not create recognizer", mapOf("code" to code))
        }
        recognizer = created
        recognizerEnvironment = environment
        recognizerMic = MicArbiter.beginDictation()
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, appContext.packageName)
            if (!language.isNullOrEmpty()) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
        }
        val started = runCatching {
            created.setRecognitionListener(Listener(created, sessionId, environment))
            created.startListening(intent)
        }
        if (started.isFailure) {
            val error = started.exceptionOrNull()
            val code = if (error is SecurityException) 9 else 5
            VoiceDiagnostics.failure(appContext, environment, code, "start", error)
            releaseRecognizer()
            return result.error("recognizer", "could not start recognizer", mapOf("code" to code))
        }
        result.success(null)
    }

    /** Callbacks of one recognizer; stale ones (after a restart) are ignored. */
    private inner class Listener(
        private val owner: SpeechRecognizer,
        private val sessionId: Long,
        private val environment: VoiceEnvironment,
    ) : RecognitionListener {
        private fun current() = recognizer === owner

        override fun onReadyForSpeech(params: Bundle?) {}

        override fun onBeginningOfSpeech() {}

        override fun onRmsChanged(rmsdB: Float) {
            // Roughly -2 (silence) .. 10 dB on most recognizers.
            if (current()) emit(sessionId, mapOf("type" to "level", "value" to ((rmsdB + 2f) / 12f).coerceIn(0f, 1f).toDouble()))
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {}

        override fun onError(error: Int) {
            if (!current()) return
            VoiceDiagnostics.failure(appContext, environment, error, "listen")
            emit(sessionId, mapOf("type" to "error", "code" to error))
            releaseRecognizer()
            emit(sessionId, mapOf("type" to "end"))
        }

        override fun onResults(results: Bundle?) {
            if (!current()) return
            if (firstText(results).isNotEmpty()) VoiceDiagnostics.success(appContext, environment)
            emit(sessionId, mapOf("type" to "final", "text" to firstText(results)))
            releaseRecognizer()
            emit(sessionId, mapOf("type" to "end"))
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (!current()) return
            val text = firstText(partialResults)
            if (text.isNotEmpty()) emit(sessionId, mapOf("type" to "partial", "text" to text))
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun firstText(bundle: Bundle?): String =
        bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim() ?: ""

    private fun releaseRecognizer() {
        val r = recognizer ?: return
        recognizer = null
        recognizerEnvironment = null
        MicArbiter.endDictation(recognizerMic)
        runCatching { r.cancel() }
        runCatching { r.destroy() }
    }

    // Recorder (engine recognizer)

    private fun startRecorder(maxSeconds: Int, sessionId: Long, result: MethodChannel.Result) {
        releaseAll()
        val environment = VoiceDiagnostics.environment(appContext)
        if (!hasPermission()) {
            VoiceDiagnostics.failure(appContext, environment, 9, "record")
            return result.error("permission", "microphone permission required", mapOf("code" to 9))
        }
        val ownGeneration = generation
        lateinit var r: WavRecorder
        r = WavRecorder(
            maxSeconds = maxSeconds.coerceIn(1, 600),
            isCurrentCapture = { generation == ownGeneration && recorder === r },
            onLevel = { level -> main.post {
                if (generation == ownGeneration && recorder === r) emit(sessionId, mapOf("type" to "level", "value" to level))
            } },
            onLimit = { main.post {
                if (generation == ownGeneration && recorder === r) emit(sessionId, mapOf("type" to "limit"))
            } },
            onError = { main.post {
                if (generation == ownGeneration && recorder === r) {
                    VoiceDiagnostics.failure(appContext, environment, 100, "record")
                    releaseAll()
                    emit(sessionId, mapOf("type" to "error", "code" to 100))
                }
            } },
        )
        val mic = MicArbiter.beginDictation()
        val started = runCatching { r.start() }
        if (started.getOrDefault(false) != true) {
            Thread {
                runCatching { r.discard() }
                main.post { MicArbiter.endDictation(mic) }
            }.start()
            VoiceDiagnostics.failure(appContext, environment, 100, "record", started.exceptionOrNull())
            return result.error("audio", "the microphone could not be opened", mapOf("code" to 100))
        }
        recorder = r
        recorderMic = mic
        result.success(null)
    }

    private fun stop(result: MethodChannel.Result) {
        recognizer?.let { current ->
            val environment = recognizerEnvironment ?: VoiceDiagnostics.environment(appContext)
            val stopped = runCatching { current.stopListening() }
            if (stopped.isFailure) {
                val error = stopped.exceptionOrNull()
                val code = if (error is SecurityException) 9 else 5
                VoiceDiagnostics.failure(appContext, environment, code, "stop", error)
                releaseRecognizer()
                return result.error("recognizer", "could not stop recognizer", mapOf("code" to code))
            }
            return result.success(null)
        }
        val r = recorder ?: return result.success(null)
        recorder = null
        val mic = recorderMic
        val environment = VoiceDiagnostics.environment(appContext)
        // Joining the capture thread and building the WAV can take a moment.
        Thread {
            val recorded = runCatching { r.finish() }
            if (recorded.isFailure) VoiceDiagnostics.failure(appContext, environment, 100, "record", recorded.exceptionOrNull())
            main.post {
                MicArbiter.endDictation(mic)
                if (recorded.isFailure) result.error("audio", "could not finish recording", mapOf("code" to 100))
                else result.success(recorded.getOrNull())
            }
        }.start()
    }

    private fun releaseAll() {
        generation++
        releaseRecognizer()
        recorder?.let { r ->
            recorder = null
            val mic = recorderMic
            Thread {
                runCatching { r.discard() }
                main.post { MicArbiter.endDictation(mic) }
            }.start()
        }
    }

    // EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        StreamingPcm.disable()
        sink = null
    }

    private fun emit(sessionId: Long, event: Map<String, Any?>) {
        sink?.success(event + ("sessionId" to sessionId))
    }

    private companion object {
        const val REQUEST_CODE = 0x5643
    }
}
