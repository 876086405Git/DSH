package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.content.Context
import android.content.SharedPreferences
import kotlin.math.roundToInt

/**
 * 设置 → 手机操控 → 悬浮条: 闲置时不透明度 (the ball's, when left alone), 「闲置时自动收起」 (an
 * open card goes back to the capsule and an idle capsule folds into the ball; off unless the person
 * turns it on), 「屏幕边缘光效」 (the glow round the screen's edge, [EdgeBeam]; on unless turned off)
 * and 「用系统灵动岛显示」 (where the phone's own island shows the task, no floating bar; on unless
 * turned off), in the overlay's own preferences file (with the ball's dock and the capsule's
 * [CapsuleSpot]). The settings page writes them through `dsh/phone` (`setOverlayPrefs`); a showing
 * overlay picks changes up at once through [SharedPreferences.OnSharedPreferenceChangeListener].
 */
data class OverlayPrefs(
    val idleOpacity: Float = DEFAULT_OPACITY,
    val autoFold: Boolean = DEFAULT_AUTO_FOLD,
    val edgeGlow: Boolean = DEFAULT_EDGE_GLOW,
    val systemIsland: Boolean = DEFAULT_SYSTEM_ISLAND,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "idleOpacity" to idleOpacity.toDouble(), "autoCollapse" to autoFold, "edgeGlow" to edgeGlow, "systemIsland" to systemIsland,
    )

    companion object {
        const val FILE = "dsh_phone_overlay"
        const val K_OPACITY = "idleOpacity"
        const val K_AUTO_FOLD = "autoFold"
        const val K_EDGE_GLOW = "edgeGlow"
        const val K_SYSTEM_ISLAND = "systemIsland"
        private const val K_CAPSULE_ANCHOR = "capsuleAnchor"
        private const val K_CAPSULE_Y = "capsuleY"

        /**
         * 70 %: an idle ball still reads as there, while the page behind shows through it. Only
         * the ball fades (all of it alike); the capsule and the card stay solid, since they carry
         * the line (docs/design/phone-overlay.md).
         */
        const val DEFAULT_OPACITY = 0.7f
        const val MIN_OPACITY = 0.3f
        const val MAX_OPACITY = 1f

        /**
         * Off: the island stays as the person left it — capsule or open card — and folds into the
         * ball only by hand. On, it gets out of the way by itself.
         */
        const val DEFAULT_AUTO_FOLD = false

        /** On: while DSH works the screen's edge glows; off leaves the screen as it is. */
        const val DEFAULT_EDGE_GLOW = true

        /** On: where the phone's own island takes the task (LiveActivity.islandShows), it is shown there instead of the floating bar. */
        const val DEFAULT_SYSTEM_ISLAND = true

        /** Within 30–100 %, on whole percents (the slider's steps are 5). */
        fun clampOpacity(v: Float): Float =
            if (v.isNaN()) DEFAULT_OPACITY else ((v.coerceIn(MIN_OPACITY, MAX_OPACITY) * 100).roundToInt() / 100f)

        fun prefs(context: Context): SharedPreferences = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

        fun read(context: Context): OverlayPrefs = from(prefs(context))

        fun from(p: SharedPreferences): OverlayPrefs = OverlayPrefs(
            clampOpacity(p.getFloat(K_OPACITY, DEFAULT_OPACITY)),
            p.getBoolean(K_AUTO_FOLD, DEFAULT_AUTO_FOLD),
            p.getBoolean(K_EDGE_GLOW, DEFAULT_EDGE_GLOW),
            p.getBoolean(K_SYSTEM_ISLAND, DEFAULT_SYSTEM_ISLAND),
        )

        /** Writes what [map] carries (`idleOpacity` 0.3–1, `autoCollapse`, `edgeGlow`, `systemIsland`); the rest stays. */
        fun write(context: Context, map: Map<*, *>?): OverlayPrefs {
            val p = prefs(context)
            val edit = p.edit()
            (map?.get("idleOpacity") as? Number)?.let { edit.putFloat(K_OPACITY, clampOpacity(it.toFloat())) }
            (map?.get("autoCollapse") as? Boolean)?.let { edit.putBoolean(K_AUTO_FOLD, it) }
            (map?.get("edgeGlow") as? Boolean)?.let { edit.putBoolean(K_EDGE_GLOW, it) }
            (map?.get("systemIsland") as? Boolean)?.let { edit.putBoolean(K_SYSTEM_ISLAND, it) }
            edit.apply()
            return from(p)
        }

        /** Where the person left the capsule last; the default spot until they move it. */
        internal fun spot(p: SharedPreferences): CapsuleSpot = CapsuleSpot(
            CapsuleAnchor.entries.firstOrNull { it.name == p.getString(K_CAPSULE_ANCHOR, null) } ?: CapsuleAnchor.CENTRE,
            p.getFloat(K_CAPSULE_Y, CapsulePlacement.TOP),
        )

        internal fun saveSpot(p: SharedPreferences, spot: CapsuleSpot) {
            p.edit().putString(K_CAPSULE_ANCHOR, spot.anchor.name).putFloat(K_CAPSULE_Y, spot.fraction).apply()
        }
    }
}
