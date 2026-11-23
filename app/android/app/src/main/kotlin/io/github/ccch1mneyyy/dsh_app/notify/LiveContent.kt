package io.github.ccch1mneyyy.dsh_app.notify

/**
 * What the live activity says: one ongoing notification Android 16 promotes to a Live Update (the
 * status bar chip, the top of the shade, the lock screen), and that HyperOS, ColorOS and MagicOS
 * draw in their islands. Pure, so the JVM tests cover it.
 *
 * Two sources: phone control (native, [LiveActivity] builds it) and the agent's runs (reduced in
 * Dart, `lib/notify/live_activity.dart`, from the same signals as the pet). Phone control wins:
 * DSH driving the phone is what the person must be able to see and stop.
 */
data class LiveContent(
    val kind: Kind,
    val title: String,
    val text: String,
    /** The chip's words (`shortCriticalText`); null: the chip shows the run's clock. */
    val chip: String?,
    /** What the lock screen shows when it hides sensitive content. */
    val publicText: String,
    /** Wall-clock start: the chronometer counts from it; null: no clock. */
    val sinceMs: Long? = null,
    /** The pet pack whose picture goes with it; null: none chosen. */
    val packId: String? = null,
    /** The pet state (Clawd's names) the picture shows. */
    val mood: String = "idle",
    /** The conversation a tap opens; null opens the app. */
    val sessionId: String? = null,
    val host: String? = null,
    val eventId: String? = null,
    /** Phone control: the task its 停止操作 stops (never whichever is selected at tap time). */
    val phoneTaskId: Long? = null,
    /** Phone control: paused, so its key says 继续. */
    val phonePaused: Boolean = false,
    /** Phone control: the app whose icon goes with it (the island shows it), once there is one; null: the pet or DSH's own. */
    val iconApp: String? = null,
) {
    enum class Kind(val wire: String) {
        PHONE("phone"),
        WAITING("waiting"),
        RUNNING("running"),
        DONE("done"),
        FAILED("failed");

        companion object {
            fun parse(wire: Any?): Kind? = values().firstOrNull { it.wire == wire }
        }
    }

    /** Still going: an indeterminate bar, refreshed while it lasts. */
    val busy: Boolean get() = kind == Kind.PHONE || kind == Kind.RUNNING

    /** A finish, shown for a moment: posted with a short timeout in case no update follows. */
    val ending: Boolean get() = kind == Kind.DONE || kind == Kind.FAILED

    /** The status bar chip's words; null while a run counts up, so the chip shows its clock. */
    val chipWords: String? get() = if (kind == Kind.RUNNING && sinceMs != null) null else chip

    companion object {
        /** The agent's live activity as Dart sends it; null for a missing or malformed one. */
        fun fromMap(m: Map<*, *>?): LiveContent? {
            m ?: return null
            val kind = Kind.parse(m["kind"])?.takeIf { it != Kind.PHONE } ?: return null
            val title = (m["title"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            fun str(key: String, max: Int) = (m[key] as? String)?.takeIf { it.isNotEmpty() }?.take(max)
            return LiveContent(
                kind = kind,
                title = title.take(TITLE_MAX),
                text = str("text", TEXT_MAX).orEmpty(),
                chip = str("chip", CHIP_MAX),
                publicText = str("publicText", TEXT_MAX) ?: title.take(TITLE_MAX),
                sinceMs = (m["sinceMs"] as? Number)?.toLong()?.takeIf { it > 0 },
                packId = str("packId", 64)?.takeIf { it != "none" },
                mood = str("mood", 32) ?: "idle",
                sessionId = str("sessionId", 200),
                host = str("host", 400),
                eventId = str("eventId", 200),
            )
        }

        /** Phone control first, then the agent. */
        fun pick(phone: LiveContent?, agent: LiveContent?): LiveContent? = phone ?: agent

        const val TITLE_MAX = 80
        const val TEXT_MAX = 160
        /** Android shows a chip's text whole up to about seven characters. */
        const val CHIP_MAX = 12
    }
}
