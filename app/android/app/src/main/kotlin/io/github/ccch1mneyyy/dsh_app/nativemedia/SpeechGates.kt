package io.github.ccch1mneyyy.dsh_app.nativemedia

import ai.onnxruntime.OrtEnvironment
import android.content.res.AssetManager
import android.util.Log
import java.io.DataInputStream

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

    private fun load(assets: AssetManager, name: String): ByteArray =
        DataInputStream(assets.open("speech/$name")).use { input ->
            // AssetInputStream reports the remaining uncompressed length of this APK asset.
            ByteArray(input.available()).also { input.readFully(it) }
        }
}
