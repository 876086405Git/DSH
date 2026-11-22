package io.github.ccch1mneyyy.dsh_app.phone.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp

/** The screen-edge rim's numbers on a phone: 1080 × 2400 px at 2.625 px/dp, corners of 110 px. */
class EdgeBeamModelTest {
    private val density = 2.625f
    private val perimeter = EdgeRim.perimeter(1080f, 2400f, 110f)
    private fun lumpsAt(t: Double) = FloatArray(EdgeRim.COUNT * EdgeRim.STRIDE).also { EdgeRim.lumps(t, perimeter, density, it) }

    // ---- 色带：整圈都有，不均匀 -----------------------------------------------------------------------

    @Test fun thePerimeterGoesRoundTheRoundedCorners() {
        assertEquals(2 * (1080f + 2400f), EdgeRim.perimeter(1080f, 2400f, 0f), 0.01f)
        // Each corner swaps two straight radii for a quarter circle.
        assertEquals(2 * (1080f + 2400f) - 8 * 110f + (2 * PI * 110).toFloat(), perimeter, 0.01f)
    }

    @Test fun theRimIsOneBandAllRoundGentlyUneven() {
        val l = lumpsAt(40.0)
        val n = 2000
        val t = FloatArray(n) { EdgeRim.thickness(perimeter * it / n, perimeter, l) }
        val mean = t.average()
        assertTrue("mean thickness $mean", mean in 0.85..1.15)
        // One band: no thin stretches between peaks, nowhere past the bound the shader's reach is built on.
        assertTrue("min ${t.min()}", t.min() >= 0.65f)
        assertTrue(t.max() <= EdgeRim.MAX_THICKNESS)
        // Lumps drifting over each other never take it past the bound the reach is built on.
        for (time in listOf(0.0, 60.0, 137.0, 600.0, 3_600.0)) {
            val m = lumpsAt(time)
            for (i in 0 until n) assertTrue(EdgeRim.thickness(perimeter * i / n, perimeter, m) <= EdgeRim.MAX_THICKNESS)
        }
        // Still a little uneven, so it doesn't read as a drawn frame.
        assertTrue("min ${t.min()} max ${t.max()}", t.max() in (1.2f * t.min())..(2.5f * t.min()))
    }

    @Test fun theColourFadesInwardToNothingWithinTheReach() {
        val w = EdgeBeamSpec.WIDTH_DP * density
        assertEquals(1f, EdgeRim.hug(0f, 1f, w), 0f)
        assertEquals(exp(-1f), EdgeRim.hug(w, 1f, w), 1e-6f)
        // At the edge of the drawn band even the thickest lump and the bloom are under half a step of 8-bit alpha.
        val reach = EdgeBeamSpec.REACH * w
        assertTrue(EdgeRim.hug(reach, EdgeRim.MAX_THICKNESS, w) * EdgeBeamSpec.DARK.rim * 255 < 0.5f)
        assertTrue(EdgeRim.hug(reach, 1f, EdgeBeamSpec.BLOOM_DP * density) * EdgeBeamSpec.DARK.bloom * 255 < 0.5f)
        assertEquals(14f, EdgeBeamSpec.WIDTH_DP, 0f)
    }

    // ---- 光束：长而柔，连成一片地绕圈 -------------------------------------------------------------------

    @Test fun theBeamsTravelRoundOnceALap() {
        assertEquals(0f, EdgeFlow.head(0.0, perimeter), 0f)
        assertEquals(perimeter / 4, EdgeFlow.head(EdgeBeamSpec.BEAM_LAP_S / 4, perimeter), 0.01f)
        assertEquals(0f, EdgeFlow.head(EdgeBeamSpec.BEAM_LAP_S * 3, perimeter), 0.01f)
        // Under a beam it is at full strength; half a lap on, the other beam is there.
        assertEquals(1f, EdgeFlow.at(100f, perimeter, 100f), 1e-3f)
        assertEquals(1f, EdgeFlow.at(100f + perimeter / 2, perimeter, 100f), 1e-3f)
    }

    @Test fun betweenTheBeamsTheBandStaysLit() {
        // Not spots circling: the rim between the beams is at least 80 % of its brightness under one.
        val n = 1000
        val glow = FloatArray(n) {
            val b = EdgeFlow.at(perimeter * it / n, perimeter, 0f)
            (1 + EdgeBeamSpec.BEAM_GAIN * b) / (1 + EdgeBeamSpec.BEAM_GAIN)
        }
        assertTrue("dimmest ${glow.min()}", glow.min() >= 0.8f)
        assertEquals(1f, glow.max(), 1e-3f)
        assertTrue(EdgeBeamSpec.CORE_REST >= 0.7f)
        assertTrue(EdgeBeamSpec.BLOOM_REST >= 0.5f)
    }

    @Test fun thePaletteFlowsRoundSlowly() {
        assertEquals(0f, EdgeFlow.hue(0.0), 0f)
        assertEquals(4.5f, EdgeFlow.hue(EdgeBeamSpec.HUE_LAP_S / 2), 1e-4f)
        assertTrue(EdgeFlow.hue(EdgeBeamSpec.HUE_LAP_S * 5 + 1) in 0f..9f)
    }

    @Test fun theLumpsDriftSlowerThanTheReference() {
        for (i in 0 until EdgeRim.COUNT) {
            val v = abs(EdgeRim.driftDpPerS(i))
            assertTrue("lump $i at $v dp/s", v <= 22 * EdgeBeamSpec.CALM)
        }
        assertTrue(EdgeBeamSpec.CALM <= 1.0)
        // Two seconds apart a lump has moved a few dp along a 2 600 dp edge: it sits there.
        val a = lumpsAt(40.0)
        val b = lumpsAt(42.0)
        for (i in 0 until EdgeRim.COUNT) {
            var d = abs(b[i * EdgeRim.STRIDE] - a[i * EdgeRim.STRIDE])
            d = minOf(d, perimeter - d)
            assertTrue("lump $i moved $d px", d / density <= 2 * 11.01f)
        }
    }

    @Test fun theLumpsBreatheButStayTheSamePattern() {
        val a = lumpsAt(0.0)
        val b = lumpsAt(0.0)
        assertTrue(a.contentEquals(b))
        val depths = (0 until 200).map { lumpsAt(it * 0.1)[2] }
        // ±25 % round the lump's own depth.
        assertTrue(depths.max() / depths.min() in 1.3f..1.7f)
        // Centres stay on the edge.
        val far = lumpsAt(100_000.0)
        for (i in 0 until EdgeRim.COUNT) assertTrue(far[i * EdgeRim.STRIDE] in 0f..perimeter)
    }

    @Test fun thePresetsReadOverAnyAppAndStayOrdered() {
        for (p in listOf(EdgeBeamSpec.DARK, EdgeBeamSpec.LIGHT)) {
            // Between the beams the rim is still clearly there (the old calm rim peaked at 0.42 / 0.26).
            assertTrue(p.rim / (1 + EdgeBeamSpec.BEAM_GAIN) >= 0.5f)
            assertTrue(p.rim <= 1f && p.core <= 1f)
            assertTrue(p.line < p.rim)
            assertTrue(p.bloom < p.rim)
        }
        // At most 60 fps.
        assertTrue(EdgeBeamSpec.FRAME_MS >= 16)
    }

    @Test fun theDisplaysCornerRadiusWinsOverTheFallback() {
        assertEquals(120f, EdgeBeamSpec.cornerPx(120, 2.625f), 0f)
        assertEquals(28 * 2.625f, EdgeBeamSpec.cornerPx(null, 2.625f), 0.001f)
        assertEquals(28 * 2.625f, EdgeBeamSpec.cornerPx(0, 2.625f), 0.001f)
    }

    // ---- 配色：跟 App 的主色 ------------------------------------------------------------------------

    @Test fun thePaletteIsTheDartPortsThemePalette() {
        // BeamPalette.fromSeed for 雾蓝 (#4B67B4), as Flutter's HSLColor rounds it.
        val p = EdgeBeamPalette.fromSeed(0xFF4B67B4.toInt())
        assertEquals(9, p.size)
        assertEquals(0xFF778CC5.toInt(), p[0])
        assertEquals(0xFF89B3C8.toInt(), p[1])
        assertEquals(0xFF8B7EC8.toInt(), p[8])
    }

    @Test fun thePaletteStaysNearTheAccentHueAndCalm() {
        for (seed in intArrayOf(0xFF4B67B4.toInt(), 0xFF236185.toInt(), 0xFFD0453B.toInt(), 0xFF808080.toInt())) {
            val (hue, _, _) = EdgeBeamPalette.hsl(seed)
            for (c in EdgeBeamPalette.fromSeed(seed)) {
                val (h, s, l) = EdgeBeamPalette.hsl(c)
                val d = abs(((h - hue + 540f) % 360f) - 180f)
                assertTrue("hue $h vs $hue", d <= 36.5f)
                assertTrue("saturation $s", s in 0.33f..0.67f)
                assertTrue("lightness $l", l in 0.57f..0.71f)
            }
        }
    }

    @Test fun theEdgesTonesAreTheThemesHuesMadeVivid() {
        for (seed in intArrayOf(0xFF4B67B4.toInt(), 0xFF236185.toInt(), 0xFFD0453B.toInt(), 0xFF808080.toInt())) {
            val theme = EdgeBeamPalette.fromSeed(seed)
            for (dark in listOf(true, false)) {
                EdgeBeamPalette.edge(seed, dark).forEachIndexed { i, c ->
                    val (h, s, l) = EdgeBeamPalette.hsl(c)
                    val (th, _, _) = EdgeBeamPalette.hsl(theme[i])
                    assertTrue("hue $h vs $th", abs(((h - th + 540f) % 360f) - 180f) <= 1.5f)
                    assertTrue("saturation $s", s in 0.59f..0.89f)
                    assertEquals(if (dark) 0.62f else 0.5f, l, 0.01f)
                }
            }
        }
    }

    @Test fun hslRoundTrips() {
        val (h, s, l) = EdgeBeamPalette.hsl(0xFF778CC5.toInt())
        assertEquals(0xFF778CC5.toInt(), EdgeBeamPalette.fromHsl(h, s, l))
    }

    @Test fun cssEase() {
        assertEquals(0.8024, BeamMath.ease(0.5), 1e-4)
        assertEquals(0.0, BeamMath.ease(0.0), 0.0)
        assertEquals(1.0, BeamMath.ease(1.0), 0.0)
    }

    // ---- 渐入渐出、暂停、移除动画 -----------------------------------------------------------------------

    @Test fun itFadesInOverSixTenthsAndOutOverHalfASecond() {
        val c = EdgeBeamClock(motion = true)
        c.show(true, 1_000)
        c.frame(1_000)
        assertEquals(0f, c.fadeNow, 0f)
        c.frame(1_300)
        assertEquals(BeamMath.ease(0.5).toFloat(), c.fadeNow, 1e-4f)
        c.frame(1_600)
        assertEquals(1f, c.fadeNow, 0f)
        assertTrue(c.animating(1_600)) // on and drifting
        c.show(false, 2_000)
        assertFalse(c.gone(2_400))
        assertTrue(c.gone(2_500))
    }

    @Test fun switchingBackMidFadeCarriesOnFromWhereItIs() {
        val c = EdgeBeamClock(motion = true)
        c.show(true, 0)
        c.show(false, 300)
        c.frame(300)
        val at = c.fadeNow
        assertTrue(at in 0.1f..0.95f)
        c.frame(301)
        assertEquals(at, c.fadeNow, 0.01f)
    }

    @Test fun pausedTheLumpsComeToRestAndNoFramesAreAskedFor() {
        val c = EdgeBeamClock(motion = true)
        c.show(true, 0)
        for (t in 0L..1_000L step 50) c.frame(t)
        assertEquals(1.0, c.phase, 1e-9)
        c.pause(true, 1_000)
        for (t in 1_050L..1_500L step 50) c.frame(t)
        assertEquals(1f, c.stillNow, 0f)
        val stopped = c.phase
        assertTrue(stopped in 1.0..1.5) // it slowed to a stop within half a second rather than halting
        c.frame(2_500)
        assertEquals(stopped, c.phase, 0.0)
        assertFalse(c.animating(2_500))
        c.pause(false, 3_000)
        assertTrue(c.animating(3_000))
    }

    @Test fun aRendererThatStandsStillAsksForFramesOnlyWhileItRamps() {
        val c = EdgeBeamClock(motion = true)
        c.show(true, 0)
        assertTrue(c.animating(100, drifts = false)) // fading in
        c.frame(EdgeBeamSpec.FADE_IN_MS)
        assertFalse(c.animating(EdgeBeamSpec.FADE_IN_MS, drifts = false)) // on, and nothing moves
        assertTrue(c.animating(EdgeBeamSpec.FADE_IN_MS)) // the shader's rim keeps drifting
        c.pause(true, 5_000)
        assertTrue(c.animating(5_100, drifts = false)) // settling into the line
    }

    @Test fun withoutAnimationsTheRimStandsStillAndPausingSwapsAtOnce() {
        val c = EdgeBeamClock(motion = false)
        c.show(true, 0)
        c.frame(0)
        assertEquals(1f, c.fadeNow, 0f)
        assertEquals(0f, c.stillNow, 0f) // the rim, not the line
        assertFalse(c.animating(0))
        c.frame(5_000)
        assertEquals(0.0, c.phase, 0.0) // nothing drifts
        c.pause(true, 5_000)
        c.frame(5_000)
        assertEquals(1f, c.stillNow, 0f)
        c.show(false, 5_010)
        assertTrue(c.gone(5_010))
    }
}
