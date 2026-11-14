package io.github.ccch1mneyyy.dsh_app.speech

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.nativemedia.MicArbiter
import io.github.ccch1mneyyy.dsh_app.nativemedia.NativeTrial
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGates
import io.github.ccch1mneyyy.dsh_app.nativemedia.TurnPause

/**
 * Speech audio for 朗读 and 语音通话: MethodChannel `dsh/speech` (lib/speech/speech_audio.dart).
 *
 * Playback — one [PcmStream] at a time: `open` {id, rate, call, levels}, `write` {id, bytes} (answers
 * the bytes waiting to play, -1 when the stream is gone), `waiting` {id}, `end` {id}, `stop`. Opening a stream stops the one before. A `call` stream plays as voice
 * communication (so the echo canceller hears it); others as media, ducking other apps.
 *
 * Calls — `callStart` {bargeIn, pause} answers "ok", "permission" or "microphone"; `callStop`; `callMute`
 * {on}; `callBargeIn` {on}; `callPause` {pause: quick|normal|patient}; `callPlaying` {on} (another player of the app's voice, such as the phone's
 * own text-to-speech, started or stopped); `callSpeaker` {on}. A call holds the app's one microphone
 * ([MicArbiter]) and puts audio in communication mode, on the loudspeaker unless a headset is there;
 * the screen stays on meanwhile (a backgrounded app gets no microphone).
 *
 * Events come back as `event` calls with a `type`: `play` {what: start|done|stopped|error, id},
 * `playLevel` {id, value}, `speechStart` {over}, `utterance` {wav, ms}, `micLevel` {value},
 * `callError` {reason}. When the person speaks over a call stream with barge-in on, the stream is
 * stopped here before `speechStart` goes out, so the voice stops at once.
 */
class SpeechPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    private val audio by lazy { context.getSystemService(AudioManager::class.java) }

    private var stream: PcmStream? = null
    private var focus: AudioFocusRequest? = null

    private var capture: CallCapture? = null
    private var mic = 0
    private var previousMode: Int? = null
    private var speaker = true
    private var externalPlaying = false
    private var activity: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        stream?.stop()
        stream = null
        endCall()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        if (capture != null) keepScreenOn(true)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        keepScreenOn(false)
        activity = null
    }

    private fun keepScreenOn(on: Boolean) {
        val window = activity?.activity?.window ?: return
        runCatching {
            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> result.success(open(call))
            "write" -> {
                val id = call.argument<String>("id")
                val bytes = call.argument<ByteArray>("bytes")
                val s = stream
                result.success(if (s != null && s.id == id && bytes != null) s.write(bytes) else -1L)
            }
            "waiting" -> {
                val s = stream
                result.success(if (s != null && s.id == call.argument<String>("id")) s.waiting() else -1L)
            }
            "end" -> {
                val s = stream
                if (s != null && s.id == call.argument<String>("id")) s.end()
                result.success(null)
            }
            "stop" -> {
                stream?.stop()
                result.success(null)
            }
            "duck" -> {
                val s = stream
                if (s != null && s.id == call.argument<String>("id")) s.duck(call.argument<Boolean>("on") == true)
                result.success(null)
            }
            "callStart" -> result.success(
                startCall(call.argument<Boolean>("bargeIn") ?: true, TurnPause.of(call.argument<String>("pause"))),
            )
            "callPause" -> {
                capture?.pause = TurnPause.of(call.argument<String>("pause"))
                result.success(null)
            }
            "callStop" -> {
                endCall()
                result.success(null)
            }
            "callMute" -> {
                capture?.muted = call.argument<Boolean>("on") == true
                result.success(null)
            }
            "callBargeIn" -> {
                capture?.bargeIn = call.argument<Boolean>("on") != false
                result.success(null)
            }
            "callPlaying" -> {
                externalPlaying = call.argument<Boolean>("on") == true
                syncPlaying()
                result.success(null)
            }
            "callSpeaker" -> {
                speaker = call.argument<Boolean>("on") != false
                if (capture != null) route()
                result.success(speaker)
            }
            else -> result.notImplemented()
        }
    }

    // ── Playback ──────────────────────────────────────────────────────────

    private fun open(call: MethodCall): Boolean {
        val id = call.argument<String>("id") ?: return false
        val rate = call.argument<Int>("rate") ?: 24000
        val forCall = call.argument<Boolean>("call") == true
        val levels = call.argument<Boolean>("levels") == true
        stream?.stop()
        val s = PcmStream(id, rate, forCall, levels, main, streamListener)
        if (!s.open()) return false
        stream = s
        if (!forCall && !requestFocus()) {
            s.stop()
            return false
        }
        return true
    }

    private val streamListener = object : PcmStream.Listener {
        override fun onStart(stream: PcmStream) {
            send("play", "what" to "start", "id" to stream.id)
            syncPlaying()
        }

        override fun onLevel(stream: PcmStream, value: Double) = send("playLevel", "id" to stream.id, "value" to value)

        override fun onDone(stream: PcmStream) = ended(stream, "done")

        override fun onStopped(stream: PcmStream) = ended(stream, "stopped")

        override fun onError(stream: PcmStream, reason: String) = ended(stream, "error")
    }

    private fun ended(s: PcmStream, what: String) {
        if (stream === s) {
            stream = null
            abandonFocus()
        }
        send("play", "what" to what, "id" to s.id)
        syncPlaying()
    }

    private fun requestFocus(): Boolean {
        val am = audio ?: return true
        val request = focus ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setOnAudioFocusChangeListener { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    main.post { stream?.takeIf { !it.call }?.stop() }
                }
            }
            .build()
            .also { focus = it }
        return am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        val request = focus ?: return
        focus = null
        runCatching { audio?.abandonAudioFocusRequest(request) }
    }

    // ── Calls ─────────────────────────────────────────────────────────────

    private fun startCall(bargeIn: Boolean, pause: TurnPause): String {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return "permission"
        }
        endCall()
        mic = MicArbiter.beginDictation()
        val marks = NativeTrial.marks(context.getSharedPreferences("speech_native", Context.MODE_PRIVATE))
        val c = CallCapture(main, captureListener) { SpeechGates.create(context.assets, it, marks) }
        c.bargeIn = bargeIn
        c.pause = pause
        val am = audio
        if (am != null) {
            previousMode = am.mode
            runCatching { am.mode = AudioManager.MODE_IN_COMMUNICATION }
        }
        route()
        if (!c.start()) {
            endCall()
            return "microphone"
        }
        capture = c
        keepScreenOn(true)
        syncPlaying()
        return "ok"
    }

    private val captureListener = object : CallCapture.Listener {
        override fun onSpeechStart(overPlayback: Boolean) {
            // Spoken over: the voice steps back at once, before Dart hears of it; Dart
            // decides from what was said whether it stops or comes back up.
            if (overPlayback) stream?.takeIf { it.call }?.duck(true)
            send("speechStart", "over" to overPlayback)
        }

        override fun onUtterance(wav: ByteArray, ms: Int) = send("utterance", "wav" to wav, "ms" to ms)

        override fun onLevel(value: Double) = send("micLevel", "value" to value)

        override fun onError(reason: String) = send("callError", "reason" to reason)
    }

    private fun syncPlaying() {
        val playing = externalPlaying || stream?.let { it.call && it.started } == true
        capture?.setPlaying(playing)
    }

    /** Loudspeaker, or the headset when one is there and the person did not ask for the speaker. */
    @Suppress("DEPRECATION")
    private fun route() {
        val am = audio ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = runCatching { am.availableCommunicationDevices }.getOrDefault(emptyList())
            val headset = devices.firstOrNull { it.type in HEADSETS }
            val target = if (speaker && headset == null) {
                devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            } else {
                headset ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
            }
            if (target != null) runCatching { am.setCommunicationDevice(target) }
        } else {
            val wired = runCatching {
                am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in HEADSETS }
            }.getOrDefault(false)
            runCatching { am.isSpeakerphoneOn = speaker && !wired }
        }
    }

    @Suppress("DEPRECATION")
    private fun endCall() {
        val c = capture
        capture = null
        c?.stop()
        if (c != null) keepScreenOn(false)
        stream?.takeIf { it.call }?.stop()
        if (mic != 0) {
            MicArbiter.endDictation(mic)
            mic = 0
        }
        val am = audio
        val mode = previousMode
        previousMode = null
        externalPlaying = false
        if (am != null && mode != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                runCatching { am.clearCommunicationDevice() }
            } else {
                runCatching { am.isSpeakerphoneOn = false }
            }
            runCatching { am.mode = mode }
        }
    }

    private fun send(type: String, vararg fields: Pair<String, Any?>) {
        val args = HashMap<String, Any?>()
        args["type"] = type
        for ((k, v) in fields) args[k] = v
        main.post { runCatching { methods.invokeMethod("event", args) } }
    }

    companion object {
        private const val CHANNEL = "dsh/speech"
        private val HEADSETS = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }
}
