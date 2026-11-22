package io.github.ccch1mneyyy.dsh_app.nativemedia

import ai.onnxruntime.OrtEnvironment
import android.content.res.AssetManager
import android.util.Log

/**
 * The models ship in the APK; where ONNX Runtime cannot load them, or once
 * crashed the app on this phone ([NativeTrial]), the energy gate does the work.
 */
object SpeechGates {
    fun create(assets: AssetManager, echoCancelled: Boolean, marks: NativeTrial.Marks): TurnGate {
        var vad: OrtSilero? = null
        var turn: OrtSmartTurn? = null
        var trial: NativeTrial? = null
        try {
            trial = NativeTrial(marks, "ort-" + OrtEnvironment.getEnvironment().version)
            if (trial.blocked()) {
                Log.w("SpeechGates", "ONNX Runtime crashed here before; using energy gate")
                return SpeechGate(echoCancelled)
            }
            val proving = !trial.proven
            if (proving) trial.begin()
            vad = OrtSilero(load(assets, "silero_vad.onnx"))
            turn = OrtSmartTurn(load(assets, "smart-turn-v3.2-cpu.onnx"))
            // Initialize the streaming VAD; smart-turn runs on its worker, and
            // once here the first time, so both have answered before the mark goes.
            vad.probability(ShortArray(512))
            vad.reset()
            if (proving) {
                turn.probability(FloatArray(NeuralGate.WINDOW_SAMPLES))
                trial.passed()
            }
            return NeuralGate(vad, turn, echoCancelled, onTurnFailed = {
                Log.w("SpeechGates", "Turn model failed; pauses end after the energy gate's hangover", it)
            })
        } catch (e: Exception) {
            trial?.dropped()
            Log.w("SpeechGates", "Neural models unavailable; using energy gate", e)
        } catch (e: LinkageError) {
            trial?.dropped()
            Log.w("SpeechGates", "ONNX Runtime unavailable; using energy gate", e)
        }
        turn?.close()
        vad?.close()
        return SpeechGate(echoCancelled)
    }

    // AssetInputStream.available() is the remaining uncompressed length, so the model
    // usually lands in one array; read to EOF anyway, since the API calls it an estimate.
    private fun load(assets: AssetManager, name: String): ByteArray = assets.open("speech/$name").use { input ->
        val head = ByteArray(input.available())
        var n = 0
        while (n < head.size) {
            val read = input.read(head, n, head.size - n)
            if (read < 0) break
            n += read
        }
        val rest = input.readBytes()
        if (n == head.size && rest.isEmpty()) head else head.copyOf(n) + rest
    }
}
