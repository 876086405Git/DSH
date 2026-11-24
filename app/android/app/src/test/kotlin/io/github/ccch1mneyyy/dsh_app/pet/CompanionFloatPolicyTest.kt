package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.*
import org.junit.Test

class CompanionFloatPolicyTest {
    private val page = "http://127.0.0.1:18457/${"a".repeat(32)}/app/index.html?mode=float&maxTexture=1024"

    @Test fun onlyThePerLaunchLoopbackCapabilityIsAccepted() {
        val endpoint = checkNotNull(CompanionFloatEndpoint.parse(page))
        assertTrue(endpoint.owns(page))
        assertTrue(endpoint.owns(page.substringBefore("/app/") + "/pack/character/model.moc3"))
        assertFalse(endpoint.owns(page.replace("18457", "18458")))
        assertFalse(endpoint.owns("https://example.com/pack/model.moc3"))
        assertFalse(endpoint.owns("http://127.0.0.1:18457/other/app/index.html"))
        assertFalse(endpoint.owns(page.substringBefore("/app/") + "/../another/file"))
        assertNull(CompanionFloatEndpoint.parse(page.replace("http:", "file:")))
        assertNull(CompanionFloatEndpoint.parse(page.replace("127.0.0.1", "localhost")))
        assertNull(CompanionFloatEndpoint.parse(page.replace("mode=float", "mode=room")))
        assertNull(CompanionFloatEndpoint.parse(page + "#another"))
        assertNull(CompanionFloatEndpoint.parse(page.replace("127.0.0.1", "user@127.0.0.1")))
    }

    @Test fun oneRetryAndOneFallbackPerSelectionSurviveWindowAndScreenCycles() {
        val policy = CompanionFloatRecovery()
        assertEquals(CompanionFloatRecovery.Failure.IGNORE, policy.failed())
        policy.select(page)
        assertEquals(CompanionFloatRecovery.Failure.RETRY, policy.failed())
        repeat(30) { policy.select(page) } // Ordinary pushes, resumes and window replacement.
        assertEquals(CompanionFloatRecovery.Failure.FALLBACK, policy.failed())
        assertTrue(policy.fallback)
        repeat(30) { assertEquals(CompanionFloatRecovery.Failure.IGNORE, policy.failed()) }
        policy.select(null)
        assertFalse(policy.fallback)
        assertEquals(CompanionFloatRecovery.Failure.IGNORE, policy.failed())
        policy.select(page)
        assertEquals(CompanionFloatRecovery.Failure.RETRY, policy.failed())
    }

    @Test fun everyKnownHiddenOrPowerGateStopsTheRendererWithoutChangingPixelPolicy() {
        fun allowed(selected: Boolean = true, fallback: Boolean = false, shown: Boolean = true,
            interactive: Boolean = true, systemShown: Boolean = true, capturing: Boolean = false,
            powerSave: Boolean = false) = companionCanRender(selected, fallback, shown,
                interactive, systemShown, capturing, powerSave)
        assertTrue(allowed())
        assertFalse(allowed(selected = false))
        assertFalse(allowed(fallback = true))
        assertFalse(allowed(shown = false))
        assertFalse(allowed(interactive = false))
        assertFalse(allowed(systemShown = false))
        assertFalse(allowed(capturing = true))
        assertFalse(allowed(powerSave = true))
        assertTrue(allowed()) // Resumption does not require consuming a fault retry.
    }

    @Test fun dimmedStartupWaitsForTheFirstPictureInsteadOfFreezingBlankShaders() {
        val freezing = CompanionFloatFreeze()
        assertNull(freezing.request(true)) // Already dimmed when the window starts.
        assertNull(freezing.onReady()) // Async shaders can still yield no alpha.
        assertNull(freezing.request(true)) // The ordinary native evaluation poll.
        assertEquals("freeze", freezing.onPicture())
        assertNull(freezing.onPicture())
        assertNull(freezing.onReady())
        assertEquals("thaw", freezing.request(false))
        assertNull(freezing.request(false))
        assertEquals("freeze", freezing.request(true))
    }

    @Test fun dimmingDuringLoadCanBeCancelledBeforeTheFirstPicture() {
        val freezing = CompanionFloatFreeze()
        assertNull(freezing.onReady())
        assertNull(freezing.request(true))
        assertNull(freezing.request(false))
        assertNull(freezing.onPicture())
        assertEquals("freeze", freezing.request(true))
        // Destruction creates a fresh controller; an old dim request cannot
        // prevent a new page from drawing its first picture.
        val resumed = CompanionFloatFreeze()
        assertNull(resumed.request(true))
        assertNull(resumed.onReady())
        assertEquals("freeze", resumed.onPicture())
    }

    @Test fun bufferPixelsScaleToFixedViewPixelsAtDifferentDensities() {
        val buffer = FramePx(1, 2, 7, 9)
        assertEquals(FramePx(1, 2, 7, 9), CompanionFloatGeometry(10, 10).fromBuffer(10, 10, buffer))
        assertEquals(FramePx(2, 4, 14, 18), CompanionFloatGeometry(20, 20).fromBuffer(10, 10, buffer))
        assertEquals(FramePx(3, 6, 21, 27), CompanionFloatGeometry(30, 30).fromBuffer(10, 10, buffer))
        // Floor left/top and ceil right/bottom retain partly occupied edge pixels.
        assertEquals(FramePx(2, 5, 18, 23), CompanionFloatGeometry(25, 25).fromBuffer(10, 10, buffer))
    }

    @Test fun ordinaryViewportKeepsTheExistingSizeAndReadbackCap() {
        val area = SafeArea(1080, 1920, 0, 40, 0, 50)
        assertEquals(CompanionFloatGeometry(288, 384), CompanionFloatGeometry.fit(384, area, 24))
        assertEquals(CompanionFloatGeometry(480, 640), CompanionFloatGeometry.fit(800, area, 24))
    }

    @Test fun landscapeAndNarrowViewportsDockEveryAcceptedBoxInsideBothMargins() {
        val cases = listOf(
            Triple(SafeArea(800, 480, 0, 48, 0, 48), 24, CompanionFloatGeometry(252, 336)),
            Triple(SafeArea(180, 720, 24, 10, 20, 30), 16, CompanionFloatGeometry(104, 640)),
        )
        for ((area, margin, expected) in cases) {
            val g = checkNotNull(CompanionFloatGeometry.fit(800, area, margin))
            assertEquals(expected, g)
            val boxes = listOf(g.whole, FramePx(1, 1, g.width, g.height),
                FramePx(g.width / 3, g.height / 3, g.width - 1, g.height - 1))
            for (side in Side.values()) for (fraction in listOf(0f, 0.5f, 1f)) for (box in boxes) {
                assertEquals(box, g.fromBuffer(g.width, g.height, box))
                val reach = g.frames(box).reach
                val rest = EdgeSnap.position(Dock(side, fraction), reach, area, margin)
                val viewport = reach.at(rest)
                assertTrue(viewport.left >= area.left + margin)
                assertTrue(viewport.right <= area.screenW - area.right - margin)
                assertTrue(viewport.top >= area.top + margin)
                assertTrue(viewport.bottom <= area.screenH - area.bottom - margin)
            }
        }
    }

    @Test fun anAreaWithNoInteriorBetweenDockMarginsDoesNotAllocateAViewport() {
        assertNull(CompanionFloatGeometry.fit(384, SafeArea(48, 480, 0, 0, 0, 0), 24))
        assertNull(CompanionFloatGeometry.fit(384, SafeArea(800, 80, 0, 20, 0, 20), 24))
        assertEquals(CompanionFloatGeometry(1, 1),
            CompanionFloatGeometry.fit(384, SafeArea(49, 49, 0, 0, 0, 0), 24))
    }

    @Test fun invalidAndEmptyBoxesCannotSizeAWindow() {
        val g = CompanionFloatGeometry(240, 320)
        assertNull(g.fromBuffer(0, 100, FramePx(0, 0, 1, 1)))
        assertNull(g.fromBuffer(100, 100, FramePx(0, 0, 0, 1)))
        assertNull(g.fromBuffer(100, 100, FramePx(-1, 0, 1, 1)))
        assertNull(g.fromBuffer(100, 100, FramePx(0, 0, 101, 1)))
        assertNull(g.fromBuffer(100, 100, FramePx(Int.MAX_VALUE, 0, Int.MIN_VALUE, 1)))
        assertEquals(g.whole, g.fromBuffer(100, 100, FramePx(0, 0, 100, 100)))
    }

    @Test fun changingAlphaBoundsKeepsViewportOriginAndDockConstant() {
        val g = CompanionFloatGeometry(240, 320)
        val area = SafeArea(1080, 1920, 0, 40, 0, 50)
        val before = FramePx(30, 40, 200, 300)
        val after = FramePx(20, 50, 210, 310)
        for (side in Side.values()) {
            val dock = Dock(side, 0.6f)
            val a = EdgeSnap.position(dock, g.frames(before).reach, area, 8)
            val b = CompanionFloatGeometry.move(a, before, after)
            assertEquals(a.x - before.left, b.x - after.left)
            assertEquals(a.y - before.top, b.y - after.top)
            assertEquals(b, EdgeSnap.position(dock, g.frames(after).reach, area, 8))
            assertEquals(190, g.frames(after).rest.width) // Touch window, not the 240 px viewport.
            assertEquals(240, g.frames(after).reach.width)
        }
    }

    @Test fun repeatedBoundsChangesAndSlideOffsetsDoNotAccumulatePositionDrift() {
        val boxes = listOf(FramePx(30, 40, 200, 300), FramePx(0, 10, 240, 310), FramePx(50, 50, 190, 290))
        var at = WindowPos(100, 200)
        var box = boxes.first()
        repeat(1000) { i ->
            val next = boxes[i % boxes.size]
            at = CompanionFloatGeometry.move(at, box, next)
            box = next
            assertEquals(70, at.x - box.left)
            assertEquals(160, at.y - box.top)
        }
        at = CompanionFloatGeometry.move(at, box, boxes.first())
        assertEquals(WindowPos(100, 200), at)
        val duringSlide = CompanionFloatGeometry.move(WindowPos(150, 250), boxes.first(), boxes.last())
        assertEquals(WindowPos(170, 260), duringSlide)
    }

    @Test fun sheTucksWhenIdleSinceHerLastBubbleAndOnlyWhileResident() {
        val tuck = CompanionTuck(30_000)
        fun at(now: Long, bubble: Boolean = false, held: Boolean = bubble, blocked: Boolean = false,
            resident: Boolean = true) = tuck.wanted(resident, bubble, held, blocked, dimmed = true, lastCallAt = 0, now = now)
        assertTrue(at(30_000))
        assertFalse(at(30_000, resident = false))
        assertFalse(at(40_000, bubble = true)) // She has something to say.
        assertFalse(at(60_000)) // A reply gets read: counted from her last bubble, not the last touch.
        assertTrue(at(70_000))
        assertFalse(at(70_000, blocked = true)) // A drag, the bar or the menu.
    }

    @Test fun putAwayByHandTakesHerReplyAlongButNotTheNextOne() {
        val tuck = CompanionTuck(30_000)
        fun want(bubble: Boolean = false) = tuck.wanted(true, bubble, held = false, blocked = false,
            dimmed = false, lastCallAt = 0, now = 1_000)
        tuck.putAway("companion:r1")
        assertTrue(want()) // At once, long before idle.
        tuck.tucked = true
        assertTrue(tuck.keeps("companion:r1")) // The rest of that reply stays tucked with her.
        assertFalse(tuck.keeps("companion:r2"))
        assertFalse(want(bubble = true)) // A new reply's bubble brings her out, and ends the put-away.
        tuck.tucked = false
        assertFalse(tuck.keeps("companion:r1"))
        assertFalse(want())
        tuck.putAway(null)
        tuck.letGo() // A tap.
        assertFalse(want())
    }
}
