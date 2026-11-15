package io.github.ccch1mneyyy.dsh_app.nativemedia

/** How long a pause has to be before the person counts as done (通话设置 → 停顿多久算说完). */
enum class TurnPause(
    /** Quiet before the turn model's "done" is believed. */
    val doneMs: Int,
    /** Quiet that ends the turn whatever the model says. */
    val forceMs: Int,
    /** Without the turn model (energy gate, or its check failed): quiet that ends the turn. */
    val hangoverMs: Int,
) {
    /** As calls were before this was a choice. */
    QUICK(200, 3000, 700),
    NORMAL(600, 3500, 1000),
    PATIENT(1200, 5000, 1600);

    companion object {
        fun of(name: String?): TurnPause = entries.firstOrNull { it.name.equals(name, ignoreCase = true) } ?: NORMAL
    }
}
