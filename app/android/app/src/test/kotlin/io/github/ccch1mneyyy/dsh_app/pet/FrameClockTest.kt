package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class FrameClockTest {
    private fun anim(vararg ms: Int, loop: Boolean = true, cells: IntArray? = null, name: String = "a") = PetAnimation(
        name, "$name.png", 8, 8, 10, PetBox(0f, 0f, 8f, 8f),
        ms.mapIndexed { i, m -> PetFrame(cells?.get(i) ?: i, m) }, loop,
    )

    @Test fun frameFollowsPerFrameTimes() {
        val a = anim(700, 280, 60)
        assertEquals(0, FrameClock.frameAt(a, 0))
        assertEquals(0, FrameClock.frameAt(a, 699))
        assertEquals(1, FrameClock.frameAt(a, 700))
        assertEquals(2, FrameClock.frameAt(a, 980))
        assertEquals(0, FrameClock.frameAt(a, 1040))
        assertEquals(1, FrameClock.frameAt(a, 1040 + 700))
        assertEquals(0, FrameClock.frameAt(a, -5))
    }

    @Test fun oneShotsHoldTheLastFrame() {
        val a = anim(100, 100, loop = false)
        assertEquals(1, FrameClock.frameAt(a, 150))
        assertEquals(1, FrameClock.frameAt(a, 10_000))
        assertNull(FrameClock.nextBoundary(a, 200))
        assertNull(FrameClock.nextChange(a, 250))
    }

    @Test fun nextBoundaryIsTheNextFrameChange() {
        val a = anim(100, 50, 200)
        assertEquals(100L, FrameClock.nextBoundary(a, 0))
        assertEquals(150L, FrameClock.nextBoundary(a, 100))
        assertEquals(350L, FrameClock.nextBoundary(a, 150))
        assertEquals(450L, FrameClock.nextBoundary(a, 350))
    }

    @Test fun repeatedCellsDontWakeTheView() {
        // 20 fps strip that holds cell 0 for four frames: the next real change is 200 ms away.
        val a = anim(50, 50, 50, 50, 50, cells = intArrayOf(0, 0, 0, 0, 1))
        assertEquals(200L, FrameClock.nextChange(a, 0))
        assertEquals(150L, FrameClock.nextChange(a, 50))
        // From the last cell, the loop back to cell 0.
        assertEquals(50L, FrameClock.nextChange(a, 200))
    }

    @Test fun idleRhythmWaitsEightToFifteenSeconds() {
        val r = IdleRhythm(Random(3))
        repeat(500) {
            val d = r.nextDelayMs()
            assertTrue(d in 8_000L..15_000L)
        }
    }

    @Test fun idleRhythmPicksByWeight() {
        val idle = anim(100, name = "idle")
        val look = anim(100, name = "look")
        val pool = listOf(PetIdleItem(idle, 4800, 3), PetIdleItem(look, 6800, 1))
        val r = IdleRhythm(Random(11))
        val counts = (1..4000).groupingBy { r.pick(pool)!!.anim.name }.eachCount()
        val share = counts.getValue("idle") / 4000.0
        assertTrue("share=$share", share in 0.70..0.80)
        assertNull(r.pick(emptyList()))
    }

    @Test fun calmStatesHoldAStillFrameThenPlayAnAction() {
        val idle = anim(100, 100, name = "idle")
        val p = PetPlayer(Random(5))
        p.setState(idle, listOf(PetIdleItem(idle, 1_000, 1)), null, now = 0)
        val still = p.frame(0)!!
        assertEquals(0, still.index)
        val wait = still.nextInMs!!
        // Nothing to draw for 8–15 s: the only wake-up is the next action.
        assertTrue(wait in 8_000L..15_000L)
        assertEquals(0, p.frame(wait - 1)!!.index)
        // The action plays at full speed for its time…
        val playing = p.frame(wait)!!
        assertEquals(100L, playing.nextInMs)
        assertEquals(1, p.frame(wait + 150)!!.index)
        // …then back to the still frame and another 8–15 s wait.
        val after = p.frame(wait + 1_000)!!
        assertEquals(0, after.index)
        assertTrue(after.nextInMs!! in 8_000L..15_000L)
    }

    @Test fun busyStatesPlayAtFullSpeed() {
        val typing = anim(150, 170, name = "typing")
        val p = PetPlayer(Random(1))
        p.setState(typing, null, null, now = 1_000)
        val f = p.frame(1_000)!!
        assertEquals("typing", f.anim.name)
        assertEquals(150L, f.nextInMs)
        assertEquals(1, p.frame(1_200)!!.index)
    }

    @Test fun bonusReplacesThePrimarySometimes() {
        val happy = anim(100, name = "happy")
        val thumbs = anim(100, name = "thumbs")
        var bonus = 0
        repeat(3000) { i ->
            val p = PetPlayer(Random(i))
            p.setState(happy, null, PetBonus(listOf(thumbs), 0.2f), now = 0)
            if (p.frame(0)!!.anim.name == "thumbs") bonus++
        }
        assertTrue("bonus=$bonus", bonus in 480..720)
    }

    @Test fun aBonusPlaysItsTimeThenTheStateLoopsFromItsFirstFrame() {
        val think = anim(100, 100, name = "think")
        val intro = anim(50, 50, 50, loop = false, name = "think-in")
        val p = PetPlayer(Random(1))
        p.setState(think, null, PetBonus(listOf(intro), 1f), now = 0, playMs = { it.totalMs })
        val first = p.frame(0)!!
        assertEquals("think-in", first.anim.name)
        assertEquals(50L, first.nextInMs)
        assertEquals(2, p.frame(120)!!.index)
        assertEquals(30L, p.frame(120)!!.nextInMs)
        val back = p.frame(150)!!
        assertEquals("think", back.anim.name)
        assertEquals(0, back.index)
        assertEquals(1, p.frame(260)!!.index)
        assertEquals("think", p.frame(10_000)!!.anim.name)
    }

    @Test fun reactionsPlayOnTopAndGiveTheStateBack() {
        val idle = anim(100, name = "idle")
        val poke = anim(100, 100, loop = false, name = "poke")
        val p = PetPlayer(Random(2))
        p.setState(idle, listOf(PetIdleItem(idle, 1_000, 1)), null, now = 0)
        p.react(poke, loop = false, now = 500)
        assertEquals("poke", p.frame(500)!!.anim.name)
        assertEquals(1, p.frame(650)!!.index)
        assertTrue(p.reacting)
        assertEquals("idle", p.frame(700)!!.anim.name)
        assertTrue(!p.reacting)
    }

    @Test fun reducedMotionTapStaysOnItsFirstFrameAndSchedulesItsReturnToTheState() {
        val idle = anim(100, name = "idle")
        val poke = anim(100, 100, loop = false, name = "poke")
        val p = PetPlayer(Random(2))
        p.still = true
        p.setState(idle, emptyList(), null, now = 0)
        p.react(poke, loop = false, now = 500)

        val first = p.frame(500)!!
        assertEquals("poke", first.anim.name)
        assertEquals(0, first.index)
        assertEquals(200L, first.nextInMs)
        val held = p.frame(650)!!
        assertEquals("poke", held.anim.name)
        assertEquals(0, held.index)
        assertEquals(50L, held.nextInMs)
        assertTrue(p.reacting)

        val after = p.frame(700)!!
        assertEquals("idle", after.anim.name)
        assertEquals(0, after.index)
        assertNull(after.nextInMs)
        assertTrue(!p.reacting)
    }

    @Test fun dragLoopsUntilEnded() {
        val idle = anim(100, name = "idle")
        val drag = anim(90, 90, name = "drag")
        val p = PetPlayer(Random(2))
        p.setState(idle, emptyList(), null, now = 0)
        p.react(drag, loop = true, now = 0)
        assertEquals("drag", p.frame(10_000)!!.anim.name)
        p.endReaction()
        assertEquals("idle", p.frame(10_001)!!.anim.name)
    }

    @Test fun reducedMotionShowsTheFirstFrameAndSchedulesNothing() {
        val typing = anim(150, 170, name = "typing")
        val p = PetPlayer(Random(1))
        p.still = true
        p.setState(typing, null, null, now = 0)
        val f = p.frame(400)!!
        assertEquals(0, f.index)
        assertNull(f.nextInMs)
        val idle = anim(100, name = "idle")
        p.setState(idle, listOf(PetIdleItem(idle, 1_000, 1)), null, now = 0)
        assertNull(p.frame(60_000)!!.nextInMs)
    }

    @Test fun nothingToPlayWithoutAState() {
        assertNull(PetPlayer().frame(0))
        assertNotNull(PetPlayer().apply { setState(anim(100), null, null, 0) }.frame(0))
    }
}
