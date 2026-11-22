package io.github.ccch1mneyyy.dsh_app.phone.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The 悬浮条 settings: defaults and the 30–100 % range (the overlay applies whatever this gives). */
class OverlayPrefsTest {
    @Test fun defaultsFoldAnIdleCapsuleAndFadeTheBallTo70Percent() {
        // 闲置时自动收起 is on unless the person turned it off: the capsule gets out of the way by itself.
        val p = OverlayPrefs()
        assertEquals(0.7f, p.idleOpacity)
        assertTrue(p.autoFold)
        assertTrue(p.edgeGlow)
        assertEquals(mapOf("idleOpacity" to 0.7f.toDouble(), "autoCollapse" to true, "edgeGlow" to true), p.toMap())
        assertFalse(p.copy(autoFold = false).toMap()["autoCollapse"] as Boolean)
        assertFalse(p.copy(edgeGlow = false).toMap()["edgeGlow"] as Boolean)
    }

    @Test fun opacityStaysWithin30And100Percent() {
        assertEquals(0.3f, OverlayPrefs.clampOpacity(0.05f))
        assertEquals(1f, OverlayPrefs.clampOpacity(1.4f))
        assertEquals(0.55f, OverlayPrefs.clampOpacity(0.55f))
        // Whole percents.
        assertEquals(0.67f, OverlayPrefs.clampOpacity(0.6666f))
        assertEquals(OverlayPrefs.DEFAULT_OPACITY, OverlayPrefs.clampOpacity(Float.NaN))
    }
}
