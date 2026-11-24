package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EdgeSnapTest {
    // A 1080×2400 phone: 96 px status bar (camera hole inside it), 63 px gesture bar.
    private val portrait = SafeArea(1080, 2400, left = 0, top = 96, right = 0, bottom = 63)

    // The same phone on its side: the cutout is now on the left edge.
    private val landscape = SafeArea(2400, 1080, left = 96, top = 0, right = 0, bottom = 63)
    private val w = 207
    private val h = 198
    private val m = 16

    @Test fun releaseSnapsToTheNearerSide() {
        assertEquals(Side.LEFT, EdgeSnap.sideFor(100, w, portrait, 0f))
        assertEquals(Side.RIGHT, EdgeSnap.sideFor(800, w, portrait, 0f))
        // Centre exactly in the middle goes right.
        assertEquals(Side.RIGHT, EdgeSnap.sideFor(440, 200, portrait, 0f))
    }

    @Test fun aFlingWinsOverPosition() {
        assertEquals(Side.RIGHT, EdgeSnap.sideFor(100, w, portrait, 2500f))
        assertEquals(Side.LEFT, EdgeSnap.sideFor(800, w, portrait, -1300f))
        // A slow drift doesn't count as a fling.
        assertEquals(Side.LEFT, EdgeSnap.sideFor(100, w, portrait, 900f))
    }

    @Test fun dockedPositionsKeepClearOfBarsAndCutout() {
        val left = EdgeSnap.position(Dock(Side.LEFT, 0f), w, h, landscape, m)
        assertEquals(96 + m, left.x)
        assertEquals(m, left.y)
        val right = EdgeSnap.position(Dock(Side.RIGHT, 1f), w, h, portrait, m)
        assertEquals(1080 - m - w, right.x)
        assertEquals(2400 - 63 - m - h, right.y)
        val top = EdgeSnap.position(Dock(Side.RIGHT, 0f), w, h, portrait, m)
        assertEquals(96 + m, top.y)
    }

    @Test fun dockSurvivesRotationAsAFraction() {
        val dock = EdgeSnap.dockFor(900, 1200, w, h, portrait, m)
        assertEquals(Side.RIGHT, dock.side)
        val lo = 96 + m
        val hi = 2400 - 63 - m - h
        assertEquals((1200 - lo).toFloat() / (hi - lo), dock.yFraction, 1e-4f)
        // Back from fraction to position on the same screen: the same y.
        assertEquals(1200, EdgeSnap.position(dock, w, h, portrait, m).y)
        // On the rotated screen it lands proportionally, still inside the safe area.
        val p = EdgeSnap.position(dock, w, h, landscape, m)
        assertTrue(p.y >= m && p.y + h <= 1080 - 63 - m)
        assertEquals(2400 - m - w, p.x)
    }

    @Test fun herFloatLeansOnTheSideOrTucksHalfPastIt() {
        val dock = Dock(Side.RIGHT, 0.5f)
        val y = EdgeSnap.position(dock, w, h, portrait, m).y
        assertEquals(WindowPos(1080 - 4 - w, y), EdgeSnap.hug(dock, w, h, portrait, m, 4, tucked = false))
        assertEquals(WindowPos(1080 - (w - w / 2), y), EdgeSnap.hug(dock, w, h, portrait, m, 4, tucked = true))
        // On its side the cutout stays clear: she leans on the safe edge, not the glass.
        assertEquals(96 + 4, EdgeSnap.hug(Dock(Side.LEFT, 0f), w, h, landscape, m, 4, tucked = false).x)
        assertEquals(96 - w / 2, EdgeSnap.hug(Dock(Side.LEFT, 0f), w, h, landscape, m, 4, tucked = true).x)
    }

    @Test fun tuckedAgainForANewCropSheKeepsHalfOnScreen() {
        // Her drawn box narrows from 207 to 61 px while tucked: shifting by the crop alone would
        // leave nothing on screen; placed again for the new width, half of her still shows.
        for (side in Side.values()) for (width in listOf(w, 61, 300)) {
            val at = EdgeSnap.hug(Dock(side, 0.5f), width, h, landscape, m, 4, tucked = true)
            val shown = minOf(at.x + width, 2400) - maxOf(at.x, 96)
            assertEquals(width - width / 2, shown)
        }
    }

    @Test fun releasedOverTheBarsClampsIntoRange() {
        assertEquals(0f, EdgeSnap.dockFor(10, -50, w, h, portrait, m).yFraction)
        assertEquals(1f, EdgeSnap.dockFor(10, 5000, w, h, portrait, m).yFraction)
    }

    @Test fun dragKeepsThePetOnScreen() {
        assertEquals(WindowPos(0, 96), EdgeSnap.clampDrag(-300, -40, w, h, portrait))
        assertEquals(WindowPos(1080 - w, 2400 - 63 - h), EdgeSnap.clampDrag(5000, 5000, w, h, portrait))
        assertEquals(WindowPos(300, 700), EdgeSnap.clampDrag(300, 700, w, h, portrait))
    }

    @Test fun tinyScreensDontInvertTheRange() {
        val tiny = SafeArea(150, 150, 0, 40, 0, 40)
        val p = EdgeSnap.position(Dock(Side.RIGHT, 0.5f), w, h, tiny, m)
        assertEquals(m, p.x)
        assertEquals(40 + m, p.y)
    }

    private fun rectAt(p: WindowPos, w: Int, h: Int) = ScreenRect(p.x, p.y, p.x + w, p.y + h)

    // A bubble card of 400 × 120 with a 10 px tail.
    private val tailH = 10

    @Test fun bubbleSitsAboveReachingInwards() {
        val pet = EdgeSnap.position(Dock(Side.RIGHT, 0.6f), w, h, portrait, m)
        val body = rectAt(pet, w, h)
        val b = EdgeSnap.bubble(body, body, Side.RIGHT, 400, 120, tailH, portrait, gap = 4, margin = m, tailInset = 40)
        assertEquals(Tail.DOWN, b.tail)
        assertEquals(pet.y - 4 - 130, b.pos.y)
        assertEquals(400 to 130, b.w to b.h)
        // Right-docked: the bubble's right edge lines up with the pet's and grows left.
        assertEquals(pet.x + w - 400, b.pos.x)
        // The tail points at the pet's middle.
        assertEquals(pet.x + w / 2, b.pos.x + b.tailAt)
    }

    @Test fun bubbleClearsThePictureNotJustTheBody() {
        val pet = EdgeSnap.position(Dock(Side.RIGHT, 0.6f), w, h, portrait, m)
        val body = rectAt(pet, w, h)
        // Mid-jump: the picture reaches 90 px above the body.
        val art = ScreenRect(body.left - 20, body.top - 90, body.right, body.bottom)
        val b = EdgeSnap.bubble(body, art, Side.RIGHT, 400, 120, tailH, portrait, gap = 4, margin = m, tailInset = 40)
        assertEquals(Tail.DOWN, b.tail)
        assertEquals(art.top - 4, b.rect.bottom)
        assertFalse(b.rect.intersects(art))
        // Still lined up with, and pointing at, the body.
        assertEquals(body.right - 400, b.pos.x)
        assertEquals(body.centerX, b.pos.x + b.tailAt)
    }

    @Test fun bubbleGoesBesideWhenThereIsNoRoomAbove() {
        val pet = EdgeSnap.position(Dock(Side.LEFT, 0f), w, h, portrait, m)
        val body = rectAt(pet, w, h)
        val b = EdgeSnap.bubble(body, body, Side.LEFT, 400, 120, tailH, portrait, gap = 4, margin = 20, tailInset = 40)
        // Left-docked: to the right of the pet, the tail pointing back at it, level with its middle.
        assertEquals(Tail.LEFT, b.tail)
        assertEquals(body.right + 4, b.pos.x)
        assertEquals(410 to 120, b.w to b.h)
        assertEquals(body.centerY - 60, b.pos.y)
        assertEquals(body.centerY, b.pos.y + b.tailAt)
        assertFalse(b.rect.intersects(body))
        // Right-docked at the top: to the left, the tail pointing right.
        val r = EdgeSnap.position(Dock(Side.RIGHT, 0f), w, h, portrait, m)
        val rb = EdgeSnap.bubble(rectAt(r, w, h), rectAt(r, w, h), Side.RIGHT, 400, 120, tailH, portrait, gap = 4, margin = 20, tailInset = 40)
        assertEquals(Tail.RIGHT, rb.tail)
        assertEquals(r.x - 4, rb.rect.right)
    }

    @Test fun bubbleGoesBelowWhenThereIsNoRoomAboveOrBeside() {
        // A narrow screen: no room beside the pet either.
        val narrow = SafeArea(400, 2400, 0, 96, 0, 63)
        val pet = EdgeSnap.position(Dock(Side.LEFT, 0f), w, h, narrow, m)
        val body = rectAt(pet, w, h)
        val b = EdgeSnap.bubble(body, body, Side.LEFT, 300, 120, tailH, narrow, gap = 4, margin = 20, tailInset = 40)
        assertEquals(Tail.UP, b.tail)
        assertEquals(pet.y + h + 4, b.pos.y)
        assertEquals(20, b.pos.x)
        assertEquals(pet.x + w / 2 - 20, b.tailAt)
    }

    @Test fun bubbleStaysOnScreenAndTailClearOfCorners() {
        // A bubble wider than the space left of a left-docked pet is pushed in from the edge.
        val pet = rectAt(WindowPos(16, 1200), 40, 40)
        val b = EdgeSnap.bubble(pet, pet, Side.LEFT, 300, 100, tailH, portrait, gap = 4, margin = 20, tailInset = 40)
        assertEquals(20, b.pos.x)
        assertEquals(40, b.tailAt)
        val far = rectAt(WindowPos(1000, 1200), 60, 60)
        val wide = EdgeSnap.bubble(far, far, Side.RIGHT, 2000, 100, tailH, portrait, gap = 4, margin = 20, tailInset = 40)
        assertEquals(20, wide.pos.x)
    }

    /**
     * Left alone it dims where it docks, never past the edge; picked up there, the window follows
     * the finger from the first pixel, both ways (a half-hidden pet used to stay clamped first).
     */
    @Test fun restingAtTheDockItIsWholeAndFollowsTheFingerAtOnce() {
        for (area in listOf(portrait, landscape)) for (side in Side.values()) {
            val rest = EdgeSnap.position(Dock(side, 0.5f), w, h, area, m)
            assertTrue(rest.x >= area.left && rest.x + w <= area.screenW - area.right)
            val inward = if (side == Side.LEFT) 1 else -1
            // Out to the edge (the margin) or any way inwards.
            for ((dx, dy) in listOf(1 to 0, -1 to 0, 0 to 1, 0 to -1, m to m, -m to -m, 300 * inward to -53)) {
                assertEquals(WindowPos(rest.x + dx, rest.y + dy), EdgeSnap.carry(rest, dx, dy, FramePx(0, 0, w, h), area))
            }
        }
    }

    @Test fun dismissTargetSitsBottomCentreAndCatchesTheCentre() {
        val c = EdgeSnap.dismissCenter(portrait, 120, 60)
        assertEquals(540, c.x)
        assertEquals(2400 - 63 - 60 - 60, c.y)
        // Landscape with a left cutout: centred in the safe width.
        assertEquals(96 + (2400 - 96) / 2, EdgeSnap.dismissCenter(landscape, 120, 60).x)
        assertTrue(EdgeSnap.overDismiss(WindowPos(c.x - 100, c.y - 75), 200, 150, c, 50))
        assertTrue(EdgeSnap.overDismiss(WindowPos(c.x - 100 + 40, c.y - 75 + 30), 200, 150, c, 50))
        assertFalse(EdgeSnap.overDismiss(WindowPos(c.x - 100 + 40, c.y - 75 + 31), 200, 150, c, 50))
    }
}

