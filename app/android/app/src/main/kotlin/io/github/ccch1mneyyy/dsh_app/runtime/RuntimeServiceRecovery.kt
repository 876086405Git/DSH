package io.github.ccch1mneyyy.dsh_app.runtime

/** Ordinary system reclamation only; the snapshot is a recovery hint, not a launch authorization. */
internal class RuntimeServiceRecovery(
    initial: Snapshot?,
    // True means the asynchronous update was submitted, not that it reached disk.
    private val publishUpdate: (Snapshot?) -> Boolean,
) {
    /** This allowlist deliberately cannot hold temporary environment variables or credentials. */
    data class Snapshot(val phoneStorage: Boolean, val visualReplies: Boolean) {
        fun encode(): Int = (if (phoneStorage) 2 else 0) + (if (visualReplies) 1 else 0)

        companion object {
            fun decode(value: Int): Snapshot? = if (value in 0..3)
                Snapshot((value and 2) != 0, (value and 1) != 0) else null
        }
    }

    private var requested: Snapshot? = null
    @Volatile private var hint: Snapshot? = initial

    val canRecreate: Boolean get() = hint != null

    @Volatile var stopOwner: String = java.util.UUID.randomUUID().toString()
        private set
    @Volatile var runStopOwner: String = stopOwner
        private set

    /** A live start can use temporary env; a new process must never silently drop it. */
    @Synchronized fun request(options: Snapshot, hasTemporaryEnvironment: Boolean, newStart: Boolean = true) {
        // Fence an old STOP before the Service consumes START and advances the runtime generation.
        if (newStart) stopOwner = java.util.UUID.randomUUID().toString()
        requested = options
        updateHint(if (hasTemporaryEnvironment) null else options)
    }

    @Synchronized fun optionsForStart(recreated: Boolean): Snapshot? = if (recreated) hint else requested ?: hint

    @Synchronized fun beginRun() {
        // Automatic stops belong to this run, even after a later request has been accepted.
        runStopOwner = stopOwner
    }

    @Synchronized fun clear() {
        requested = null
        updateHint(null)
    }

    private fun updateHint(next: Snapshot?) {
        hint = null
        // A new process with no snapshot on disk refuses recovery, even after an accepted update.
        if (publishUpdate(next)) hint = next
    }

    companion object {
        fun acceptsStop(expectedGeneration: Int?, generation: Int, expectedOwner: String?, owner: String): Boolean =
            expectedGeneration == null || (expectedGeneration == generation && expectedOwner == owner)
    }
}
