package io.github.ccch1mneyyy.dsh_app.nativemedia

/** A capture owns a gate and serializes calls; edges are emitted only by [consume]. */
interface TurnGate : AutoCloseable {
    fun consume(frame: ShortArray, levelDb: Double, nowMs: Long): SpeechGate.Edge
    fun setPlaying(on: Boolean, nowMs: Long)

    /** How long a pause ends the turn; may change between frames. */
    var pause: TurnPause
    fun reset() {}
    override fun close() {}
}
