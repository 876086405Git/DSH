package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.pet.Dock
import io.github.ccch1mneyyy.dsh_app.pet.EdgeSnap
import io.github.ccch1mneyyy.dsh_app.pet.SafeArea
import io.github.ccch1mneyyy.dsh_app.pet.Side
import io.github.ccch1mneyyy.dsh_app.pet.WindowPos
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The capsule's place, the ball against it and the screen sides, at 2.625 px/dp (a 1080 px phone, 411 dp wide). */
class BallGeometryTest {
    private val density = 2.625f
    private fun dp(v: Int) = Math.round(v * density)
    private fun assertNear(expected: Int, actual: Int) = assertTrue("$actual vs $expected", kotlin.math.abs(actual - expected) <= 1)

    private val area = SafeArea(1080, 2400, left = 0, top = 96, right = 0, bottom = 63)
    private val ball = dp(OverlayBall.BALL_DP)
    private val pad = dp(OverlayBall.PAD_DP)
    private val size = ball + 2 * pad
    private val edge = dp(OverlayBall.EDGE_DP)
    private val margin = BallGeometry.margin(edge, pad)
    private val headerH = dp(CapsuleMetrics.HEIGHT_DP)
    private val gap = dp(CapsulePlacement.GAP_DP)

    // The capsule as ControlOverlay places it: centred, hung from the bottom, its root padding the surface.
    private val padX = dp(OverlayCapsule.PAD_X_DP)
    private val padTop = dp(OverlayCapsule.PAD_TOP_DP)
    private val padBottom = dp(OverlayCapsule.PAD_BOTTOM_DP)
    private val capsuleW = dp(240)
    private val windowW = capsuleW + 2 * padX
    private val windowH = headerH + padTop + padBottom
    private val centre = CapsulePlacement.centreY(area, headerH, gap)
    private val windowX = CapsulePlacement.windowX(CapsulePlacement.capsuleLeft(CapsuleAnchor.CENTRE, area, capsuleW, edge), padX, 0)
    private val windowY = CapsulePlacement.windowTop(area.screenH, CapsulePlacement.windowY(area.screenH, centre, headerH, padBottom), windowH)

    private fun end(side: Side) = BallGeometry.ballOver(
        windowX, windowY, padX, padTop, BallGeometry.circleLeft(0, capsuleW, ball, side), 0, pad,
    )

    @Test fun theBallIsTheCapsulesHeight() {
        // One object: the ball is the capsule's end circle, and every form has the same corner.
        assertEquals(CapsuleMetrics.HEIGHT_DP, OverlayBall.BALL_DP)
        assertEquals(CapsuleMetrics.HEIGHT_DP / 2, CapsuleMetrics.RADIUS_DP)
        assertTrue(OverlayBall.BALL_DP >= 48)
    }

    // ---- 胶囊在屏幕中下方 ---------------------------------------------------------------------------

    @Test fun theCapsuleSitsInTheLowerMiddleOfTheSafeArea() {
        val safeH = area.screenH - area.top - area.bottom
        val share = (centre - area.top).toFloat() / safeH
        assertTrue("at $share of the safe height", share in 0.70f..0.75f)
        // Centred across.
        assertEquals(area.screenW - (windowX + windowW), windowX)
        // Clear of the navigation bar.
        assertTrue(centre + headerH / 2 <= area.screenH - area.bottom - gap)
    }

    @Test fun theWindowHangsFromTheBottomAroundTheCapsule() {
        val y = CapsulePlacement.windowY(area.screenH, centre, headerH, padBottom)
        // A taller window (the card) keeps its bottom edge, so the header stays where the capsule was.
        val cardH = dp(320) + padTop + padBottom
        val capsuleBottom = CapsulePlacement.windowTop(area.screenH, y, windowH) + windowH
        val cardBottom = CapsulePlacement.windowTop(area.screenH, y, cardH) + cardH
        assertEquals(capsuleBottom, cardBottom)
        assertEquals(centre + headerH / 2, cardBottom - padBottom)
        // The surface's top in the capsule window is the capsule's.
        assertEquals(centre - headerH / 2, windowY + padTop)
    }

    @Test fun aConfirmCardOrAKeyboardPushesTheCapsuleUpOverIt() {
        val cardTop = 1300
        val lifted = CapsulePlacement.centreY(area, headerH, gap, obstacleTop = cardTop)
        assertEquals(cardTop - gap - headerH / 2, lifted)
        assertTrue(lifted < centre)
        // Something low (a short keyboard under the capsule's place) changes nothing.
        assertEquals(centre, CapsulePlacement.centreY(area, headerH, gap, obstacleTop = area.screenH - area.bottom))
        // Something reaching the top never pushes it under the status bar.
        assertEquals(area.top + gap + headerH / 2, CapsulePlacement.centreY(area, headerH, gap, obstacleTop = area.top + 10))
    }

    @Test fun landscapeKeepsTheSameShareOfTheSafeHeight() {
        val land = SafeArea(2400, 1080, left = 96, top = 0, right = 63, bottom = 0)
        assertEquals(778, CapsulePlacement.centreY(land, headerH, gap)) // 0.72 × 1080
    }

    @Test fun aShortScreenWithTheKeyboardUpCapsTheCardUnderTheStatusBar() {
        // Landscape, a 200 dp keyboard: the header sits above it, the card's body scrolls in what is left.
        val land = SafeArea(2400, 1080, left = 96, top = 0, right = 63, bottom = 0)
        val keyboardTop = 1080 - dp(200)
        val c = CapsulePlacement.centreY(land, headerH, gap, obstacleTop = keyboardTop)
        assertEquals(keyboardTop - gap - headerH / 2, c)
        val room = CapsulePlacement.cardRoom(land, c, headerH, gap)
        val headerPart = headerH - dp(6) // the body tucks 6 dp into the header
        val body = CapsulePlacement.bodyHeight(natural = dp(320), maxCard = room, headerPart = headerPart)
        val cardTop = c + headerH / 2 - (headerPart + body)
        assertEquals(land.top + gap, cardTop)
        assertTrue(body < dp(320))
    }

    @Test fun aCardThatFitsKeepsItsHeight() {
        val room = CapsulePlacement.cardRoom(area, centre, headerH, gap)
        assertEquals(dp(300), CapsulePlacement.bodyHeight(natural = dp(300), maxCard = room, headerPart = headerH))
        // No room at all: no body, never a negative one.
        assertEquals(0, CapsulePlacement.bodyHeight(natural = dp(300), maxCard = headerH / 2, headerPart = headerH))
        assertEquals(dp(300), CapsulePlacement.bodyHeight(natural = dp(300), maxCard = Int.MAX_VALUE, headerPart = headerH))
    }

    // ---- 小球 ------------------------------------------------------------------------------------

    @Test fun aBallNeverMovedRestsOnTheRightLevelWithTheCapsule() {
        val dock = BallGeometry.dockLevel(area, size, margin, centre)
        assertEquals(Side.RIGHT, dock.side)
        val pos = EdgeSnap.position(dock, size, size, area, margin)
        assertEquals(centre.toFloat(), pos.y + size / 2f, 1f)
    }

    @Test fun aRestingBallLiftsAboveAConfirmCard() {
        val minY = EdgeSnap.minY(area, margin)
        val pos = WindowPos(900, 1600)
        assertEquals(pos, BallGeometry.above(pos, size, limit = null, minY = minY))
        assertEquals(pos, BallGeometry.above(pos, size, limit = 1600 + size, minY = minY))
        assertEquals(WindowPos(900, 1200 - size), BallGeometry.above(pos, size, limit = 1200, minY = minY))
        // Never above the safe area.
        assertEquals(WindowPos(900, minY), BallGeometry.above(pos, size, limit = minY + 10, minY = minY))
    }

    @Test fun dockedBallsSitTheSameGapFromEitherSide() {
        val left = EdgeSnap.position(Dock(Side.LEFT, 0.3f), size, size, area, margin)
        val right = EdgeSnap.position(Dock(Side.RIGHT, 0.3f), size, size, area, margin)
        val leftGap = left.x + pad
        val rightGap = area.screenW - (right.x + pad + ball)
        assertEquals(edge, leftGap)
        assertEquals(edge, rightGap)
        // Mirror images: same height.
        assertEquals(left.y, right.y)
    }

    @Test fun theFoldStartsOnTheCapsulesEndCircle() {
        val surfaceLeft = windowX + padX
        val surfaceTop = windowY + padTop
        val r = end(Side.RIGHT)
        assertEquals(surfaceLeft + capsuleW - ball, r.x + pad)
        assertEquals(surfaceTop, r.y + pad)
        val l = end(Side.LEFT)
        assertEquals(surfaceLeft, l.x + pad)
        assertEquals(r.y, l.y)
        // The circle is the capsule's own: centred on the capsule's centre line.
        assertEquals(centre, r.y + pad + ball / 2)
    }

    @Test fun theTwoEndsAreMirrorImagesAboutTheScreensCentre() {
        val r = end(Side.RIGHT)
        val l = end(Side.LEFT)
        val leftOfLeft = l.x + pad
        val rightOfRight = r.x + pad + ball
        assertTrue(kotlin.math.abs((leftOfLeft + rightOfRight) - area.screenW) <= 1)
    }

    @Test fun aCircleAtEitherEndOfAWideCard() {
        // From the card, the fold goes to the header's end: the card's corner circle.
        val cardW = CapsuleMetrics.maxPx(area.screenW, density)
        assertEquals(cardW - ball, BallGeometry.circleLeft(0, cardW, ball, Side.RIGHT))
        assertEquals(0, BallGeometry.circleLeft(0, cardW, ball, Side.LEFT))
        assertEquals(30, BallGeometry.circleLeft(30, 30 + cardW, ball, Side.LEFT))
    }

    // ---- 胶囊可拖：纵向记住、横向三个锚点 --------------------------------------------------------------------

    @Test fun aDraggedCapsuleKeepsItsHeightAsAShareOfTheSafeHeight() {
        val dropped = 700
        val f = CapsulePlacement.fractionFor(area, dropped, headerH, gap)
        assertNear(dropped, CapsulePlacement.centreY(area, headerH, gap, fraction = f))
        // The same share on a landscape screen: it survives rotation.
        val land = SafeArea(2400, 1080, left = 96, top = 0, right = 63, bottom = 0)
        assertNear((1080 * f).toInt(), CapsulePlacement.centreY(land, headerH, gap, fraction = f))
        // Let go over the status bar or the navigation bar: kept 12 dp clear of them.
        val top = CapsulePlacement.centreY(area, headerH, gap, fraction = CapsulePlacement.fractionFor(area, 0, headerH, gap))
        assertEquals(area.top + gap + headerH / 2, top)
        val bottom = CapsulePlacement.centreY(area, headerH, gap, fraction = CapsulePlacement.fractionFor(area, 5000, headerH, gap))
        assertEquals(area.screenH - area.bottom - gap - headerH / 2, bottom)
        assertEquals(area.top + gap + headerH / 2, CapsulePlacement.clampCentre(area, -50, headerH, gap))
    }

    @Test fun aDraggedCapsuleStillMovesUpOverTheKeyboardAndComesBack() {
        val f = CapsulePlacement.fractionFor(area, 1900, headerH, gap)
        val keyboardTop = 1400
        assertEquals(keyboardTop - gap - headerH / 2, CapsulePlacement.centreY(area, headerH, gap, keyboardTop, f))
        assertNear(1900, CapsulePlacement.centreY(area, headerH, gap, null, f))
        // One dragged up high stays where it is: the keyboard is far below it.
        val high = CapsulePlacement.fractionFor(area, 400, headerH, gap)
        assertNear(400, CapsulePlacement.centreY(area, headerH, gap, keyboardTop, high))
    }

    @Test fun aCapsuleUpHighMovesDownWhileTheCardIsOpenSoTheCardFits() {
        val f = CapsulePlacement.fractionFor(area, 300, headerH, gap)
        val cardH = dp(320)
        val open = CapsulePlacement.centreY(area, headerH, gap, fraction = f, cardH = cardH)
        // Just low enough: the card's top is 12 dp under the status bar.
        assertEquals(area.top + gap, open + headerH / 2 - cardH)
        assertEquals(cardH, CapsulePlacement.cardRoom(area, open, headerH, gap))
        // Closed again: back where it was.
        assertNear(300, CapsulePlacement.centreY(area, headerH, gap, fraction = f))
        // Low enough already: the card changes nothing.
        assertEquals(centre, CapsulePlacement.centreY(area, headerH, gap, cardH = cardH))
    }

    @Test fun theThreeAnchorsSit12DpFromTheSidesOrInTheMiddle() {
        assertEquals(edge, CapsulePlacement.capsuleLeft(CapsuleAnchor.LEFT, area, capsuleW, edge))
        assertEquals(area.screenW - edge - capsuleW, CapsulePlacement.capsuleLeft(CapsuleAnchor.RIGHT, area, capsuleW, edge))
        assertEquals((area.screenW - capsuleW) / 2, CapsulePlacement.capsuleLeft(CapsuleAnchor.CENTRE, area, capsuleW, edge))
        // Landscape with the bar on the left: clear of it.
        val land = SafeArea(2400, 1080, left = 96, top = 0, right = 63, bottom = 0)
        assertEquals(96 + edge, CapsulePlacement.capsuleLeft(CapsuleAnchor.LEFT, land, capsuleW, edge))
        assertEquals(2400 - 63 - edge - capsuleW, CapsulePlacement.capsuleLeft(CapsuleAnchor.RIGHT, land, capsuleW, edge))
    }

    @Test fun letGoTheCapsuleSnapsToTheNearestAnchorOrTheSideItWasThrownTo() {
        assertEquals(CapsuleAnchor.LEFT, CapsulePlacement.anchorFor(80, capsuleW, area, edge, 0f))
        assertEquals(CapsuleAnchor.CENTRE, CapsulePlacement.anchorFor(240, capsuleW, area, edge, 0f))
        assertEquals(CapsuleAnchor.RIGHT, CapsulePlacement.anchorFor(area.screenW - capsuleW - 60, capsuleW, area, edge, 0f))
        // Thrown: the side it went, wherever it was let go.
        assertEquals(CapsuleAnchor.RIGHT, CapsulePlacement.anchorFor(80, capsuleW, area, edge, 2000f))
        assertEquals(CapsuleAnchor.LEFT, CapsulePlacement.anchorFor(240, capsuleW, area, edge, -2000f))
    }

    @Test fun draggedOffASideTheCapsuleFoldsIntoTheBallThere() {
        val out = dp(CapsulePlacement.FOLD_OUT_DP)
        val w = area.screenW
        // Just touching the side, or a little past it: still a capsule (it snaps back to the anchor).
        assertEquals(null, CapsulePlacement.foldSide(0, capsuleW, w, out, 0f))
        assertEquals(null, CapsulePlacement.foldSide(-out + 1, capsuleW, w, out, 0f))
        assertEquals(null, CapsulePlacement.foldSide(w - capsuleW + out - 1, capsuleW, w, out, 0f))
        // Far enough past it.
        assertEquals(Side.LEFT, CapsulePlacement.foldSide(-out, capsuleW, w, out, 0f))
        assertEquals(Side.RIGHT, CapsulePlacement.foldSide(w - capsuleW + out, capsuleW, w, out, 0f))
        // A little past it and thrown outward.
        assertEquals(Side.LEFT, CapsulePlacement.foldSide(-4, capsuleW, w, out, -1500f))
        assertEquals(Side.RIGHT, CapsulePlacement.foldSide(w - capsuleW + 4, capsuleW, w, out, 1500f))
        // Thrown inward, or thrown while still on screen: no fold.
        assertEquals(null, CapsulePlacement.foldSide(-4, capsuleW, w, out, 1500f))
        assertEquals(null, CapsulePlacement.foldSide(40, capsuleW, w, out, -3000f))
    }

    @Test fun theCapsuleGrowsFromItsAnchorsSide() {
        val wide = capsuleW + dp(80)
        // Against the left: the left end stays; against the right: the right end stays.
        assertEquals(0, CapsulePlacement.leftIn(CapsuleAnchor.LEFT, wide, capsuleW))
        assertEquals(wide - capsuleW, CapsulePlacement.leftIn(CapsuleAnchor.RIGHT, wide, capsuleW))
        assertEquals((wide - capsuleW) / 2, CapsulePlacement.leftIn(CapsuleAnchor.CENTRE, wide, capsuleW))
        for (anchor in CapsuleAnchor.entries) {
            val before = CapsulePlacement.capsuleLeft(anchor, area, capsuleW, edge)
            val after = CapsulePlacement.capsuleLeft(anchor, area, wide, edge)
            when (anchor) {
                CapsuleAnchor.LEFT -> assertEquals(before, after)
                CapsuleAnchor.RIGHT -> assertEquals(before + capsuleW, after + wide)
                CapsuleAnchor.CENTRE -> assertNear(before + capsuleW / 2, after + wide / 2)
            }
        }
    }

    @Test fun aCutoutOnOneSideNarrowsTheCardSoItStillEndsOnScreen() {
        // A narrow screen with a bar down its left: the left anchor starts inside the bar.
        val narrow = SafeArea(1080, 2400, left = 96, top = 96, right = 0, bottom = 63)
        val cardW = CapsuleMetrics.maxPx(CapsulePlacement.roomW(narrow), density)
        for (anchor in CapsuleAnchor.entries) {
            val capLeft = CapsulePlacement.capsuleLeft(anchor, narrow, capsuleW, edge)
            val cardLeft = capLeft - CapsulePlacement.leftIn(anchor, cardW, capsuleW)
            assertTrue("$anchor card at $cardLeft", cardLeft >= 0 && cardLeft + cardW <= narrow.screenW)
        }
    }

    @Test fun theCardSitsOnTheCapsulesSideAndStaysOnScreen() {
        val cardW = CapsuleMetrics.maxPx(area.screenW, density)
        for (anchor in CapsuleAnchor.entries) {
            val capLeft = CapsulePlacement.capsuleLeft(anchor, area, capsuleW, edge)
            val inCard = CapsulePlacement.leftIn(anchor, cardW, capsuleW)
            val x = CapsulePlacement.windowX(capLeft, padX, inCard)
            val cardLeft = x + padX
            assertEquals(capLeft, cardLeft + inCard) // the header stays where the capsule was
            assertTrue("$anchor card at $cardLeft", cardLeft >= 0 && cardLeft + cardW <= area.screenW)
        }
    }

    // ---- 小球贴边半藏 --------------------------------------------------------------------------------

    @Test fun anIdleBallTucksHalfOutOfSightOverItsSide() {
        val right = EdgeSnap.position(Dock(Side.RIGHT, 0.5f), size, size, area, margin)
        val t = BallGeometry.tucked(right, Side.RIGHT, area, pad, ball)
        // Its centre on the screen's edge: half of it shows, at the same height.
        assertEquals(area.screenW, t.x + pad + ball / 2)
        assertEquals(right.y, t.y)
        val left = EdgeSnap.position(Dock(Side.LEFT, 0.5f), size, size, area, margin)
        assertEquals(0, BallGeometry.tucked(left, Side.LEFT, area, pad, ball).x + pad + ball / 2)
        // The window's part still on screen (where touches land): the half ball and the room beside it.
        assertEquals(ball / 2 + pad, area.screenW - t.x)
        // Landscape, the bar on the right: on the bar's inner edge, not under it.
        val land = SafeArea(2400, 1080, left = 96, top = 0, right = 63, bottom = 0)
        assertEquals(2400 - 63, BallGeometry.tucked(WindowPos(0, 0), Side.RIGHT, land, pad, ball).x + pad + ball / 2)
    }

    // ---- 默认顶部居中的岛：卡片向下展开，小球收在正中 -------------------------------------------------------

    @Test fun theDefaultIslandSitsAtTheTopCentreUnderTheStatusBarAndOpensDown() {
        val spot = CapsuleSpot()
        assertEquals(CapsuleAnchor.CENTRE, spot.anchor)
        assertEquals(CapsulePlacement.TOP, spot.fraction)
        val top = CapsulePlacement.centreY(area, headerH, gap, fraction = spot.fraction)
        // As high as it goes: its top a gap under the status bar.
        assertEquals(area.top + gap, top - headerH / 2)
        assertTrue(CapsulePlacement.opensDown(area, top))
        // Symmetric: as far from either side.
        val left = CapsulePlacement.capsuleLeft(CapsuleAnchor.CENTRE, area, capsuleW, edge)
        assertNear(left, area.screenW - (left + capsuleW))
        // Hung from the top, the window's surface starts at the capsule's top.
        assertEquals(top - headerH / 2, CapsulePlacement.windowTopY(top, headerH, padTop) + padTop)
        // Lower down the card opens up, as before.
        assertTrue(!CapsulePlacement.opensDown(area, centre))
    }

    @Test fun aCardOpeningDownGetsTheRoomDownToTheBarOrTheKeyboard() {
        val top = CapsulePlacement.centreY(area, headerH, gap, fraction = CapsulePlacement.TOP)
        val capsuleTop = top - headerH / 2
        assertEquals(area.screenH - area.bottom - gap - capsuleTop, CapsulePlacement.cardRoomBelow(area, top, headerH, gap))
        val keyboard = 1500
        assertEquals(keyboard - gap - capsuleTop, CapsulePlacement.cardRoomBelow(area, top, headerH, gap, keyboard))
    }

    @Test fun aDownwardCardLiftsOverTheKeyboardForItsBodyNotJustTheHeader() {
        val keyboard = 1500
        val low = 1300
        val cardH = 600
        // Room for the whole card over the keyboard: its bottom a gap above it.
        val lifted = CapsulePlacement.liftForCard(area, low, headerH, gap, keyboard, cardH)
        assertEquals(cardH, CapsulePlacement.cardRoomBelow(area, lifted, headerH, gap, keyboard))
        // Never above the gap under the status bar; with no keyboard it stays put.
        assertEquals(area.top + gap + headerH / 2, CapsulePlacement.liftForCard(area, low, headerH, gap, keyboard, 5000))
        assertEquals(low, CapsulePlacement.liftForCard(area, low, headerH, gap, null, cardH))
    }

    @Test fun anIslandAtTheTopFoldsIntoABallInItsMiddle() {
        val top = CapsulePlacement.centreY(area, headerH, gap, fraction = CapsulePlacement.TOP)
        val wx = CapsulePlacement.windowX(CapsulePlacement.capsuleLeft(CapsuleAnchor.CENTRE, area, capsuleW, edge), padX, 0)
        val wy = CapsulePlacement.windowTopY(top, headerH, padTop)
        assertEquals((capsuleW - ball) / 2, BallGeometry.circleLeft(0, capsuleW, ball, null))
        val over = BallGeometry.ballOver(wx, wy, padX, padTop, BallGeometry.circleLeft(0, capsuleW, ball, null), 0, pad)
        // The circle the island shrinks to is where the ball rests at the top centre: no glide after the fold.
        val rest = BallGeometry.topCentre(area, size, top)
        assertNear(rest.x, over.x)
        assertEquals(rest.y, over.y)
        assertNear(area.screenW / 2, rest.x + size / 2)
    }

    @Test fun aBallLetGoNearTheTopCentreGoesBackThere() {
        val y = area.top + ball / 2
        assertTrue(BallGeometry.nearTopCentre(area.screenW / 2, y, area, ball))
        assertTrue(BallGeometry.nearTopCentre(area.screenW / 2 + area.screenW / 8, y, area, ball))
        // Towards a side, or lower down: a side dock.
        assertTrue(!BallGeometry.nearTopCentre(area.screenW - ball, y, area, ball))
        assertTrue(!BallGeometry.nearTopCentre(area.screenW / 2, area.top + 3 * ball, area, ball))
    }

    @Test fun aCapsuleDraggedOffASideBecomesABallLevelWithIt() {
        val at = 900
        for (side in Side.entries) {
            val dock = BallGeometry.dockLevel(area, size, margin, at, side)
            assertEquals(side, dock.side)
            assertEquals(at.toFloat(), EdgeSnap.position(dock, size, size, area, margin).y + size / 2f, 1f)
        }
    }
}
