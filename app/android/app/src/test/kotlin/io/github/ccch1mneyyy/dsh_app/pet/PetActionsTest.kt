package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.*
import org.junit.Test

class PetActionsTest {
    private fun ask(text: String = "bash {\"command\":\"echo ok\"}", token: Long? = 1) =
        PetAsk(eventId = "e", token = token, kind = PetAsk.APPROVAL, text = text, approvable = true, choices = emptyList())

    @Test fun onlyWholeCurrentRequestsCanBeAnswered() {
        assertEquals(listOf(BubbleAction.Kind.REJECT, BubbleAction.Kind.ALLOW), BubbleAction.of(ask(), true).map { it.kind })
        assertEquals(listOf(BubbleAction.Kind.OPEN), BubbleAction.of(ask(), false).map { it.kind })
        assertEquals(listOf(BubbleAction.Kind.OPEN), BubbleAction.of(ask(token = null), true).map { it.kind })
        val oversized = PetAsk.fromMap(mapOf("eventId" to "e", "token" to 1, "kind" to "approval", "text" to "x".repeat(400), "approvable" to true))!!
        assertFalse(oversized.approvable)
        assertEquals(BubbleAction.Kind.OPEN, BubbleAction.of(oversized, true).single().kind)
    }

    @Test fun choicesAreAllOrNothing() {
        fun question(choices: List<String>) = PetAsk.fromMap(mapOf("eventId" to "e", "token" to 1,
            "kind" to "question", "text" to "Pick", "choices" to choices))!!
        assertEquals(listOf("A", "B", "C"), BubbleAction.of(question(listOf("A", "B", "C")), true).map { it.choice })
        assertEquals(BubbleAction.Kind.OPEN, BubbleAction.of(question(listOf("A", "B", "C", "D")), true).single().kind)
        assertEquals(BubbleAction.Kind.OPEN, BubbleAction.of(question(listOf("A", "x".repeat(25))), true).single().kind)
    }

    @Test fun barRetainsHostIdentityAndOfferAndCanSwitchToFresh() {
        val target = AskTarget.fromMap(mapOf("offer" to 42L, "current" to mapOf("host" to "host-a", "sessionId" to "s", "line" to "Work"),
            "fresh" to mapOf("host" to "host-a", "line" to "New chat"), "voice" to "ready"))!!
        assertEquals(42L, target.offer)
        assertTrue(target.canSwitch)
        assertEquals("s", target.chat(false)?.sessionId)
        assertNull(target.chat(true)?.sessionId)
        assertEquals("host-a", target.chat(true)?.host)
        assertEquals(AskTarget.VOICE_READY, target.voice)
    }

    @Test fun cannotSendWhileBusyBlockedOrRecording() {
        assertTrue(AskBarView.canSend("hello", false, false, false))
        assertFalse(AskBarView.canSend("  ", false, false, false))
        assertFalse(AskBarView.canSend("hello", true, false, false))
        assertFalse(AskBarView.canSend("hello", false, true, false))
        assertFalse(AskBarView.canSend("hello", false, false, true))
    }

    @Test fun menuOnlyOffersApplicableShortcuts() {
        val base = PetPush.fromMap(mapOf("packId" to "deepy-whale"), 100)
        assertEquals(listOf(PetMenuItem.ASK, PetMenuItem.NEW_CHAT, PetMenuItem.SCREENSHOT, PetMenuItem.SNOOZE, PetMenuItem.SETTINGS), PetMenuItem.of(base, screenshots = true))
        assertEquals(listOf(PetMenuItem.ASK, PetMenuItem.NEW_CHAT, PetMenuItem.SNOOZE, PetMenuItem.SETTINGS), PetMenuItem.of(base, screenshots = false))
        val busy = base.copy(canStop = true, hosts = listOf(PetHost("a", "A", true), PetHost("b", "B", false)))
        assertTrue(PetMenuItem.of(busy, screenshots = true).containsAll(listOf(PetMenuItem.STOP, PetMenuItem.SWITCH_HOST)))
        assertEquals(7, PetMenuItem.of(busy, screenshots = true).size)
        assertEquals(listOf(PetMenuItem.ASK, PetMenuItem.ROOM, PetMenuItem.TUCK, PetMenuItem.HIDE_HOUR),
            PetMenuItem.companion(base, watching = false, tuck = true))
        assertEquals(listOf(PetMenuItem.ASK, PetMenuItem.ROOM, PetMenuItem.UNWATCH, PetMenuItem.STOP, PetMenuItem.HIDE_HOUR),
            PetMenuItem.companion(busy, watching = true, tuck = false))
    }

    @Test fun openBarKeepsPetVisibleAndUndimmedButDoesNotOverrideLockOrForeground() {
        val machine = OverlayMachine().apply {
            enabled = true; canHost = true; hasPet = true
            onForeground(false, 1)
            onPush(PetPush.fromMap(mapOf("packId" to "deepy-whale", "active" to false), 1), 1)
            holding = true
        }
        assertEquals(Visibility.SHOWN, machine.decide(600_000).visibility)
        assertFalse(machine.decide(600_000).dimmed)
        machine.interactive = false
        assertEquals(Visibility.PAUSED, machine.decide(600_000).visibility)
        machine.onForeground(true, 600_000)
        assertEquals(Visibility.HIDDEN, machine.decide(600_000).visibility)
    }

    @Test fun inputBarStaysInsideNarrowDisplayAndAboveIme() {
        val area = SafeArea(320, 640, left = 0, top = 24, right = 0, bottom = 24)
        val pet = ScreenRect(260, 400, 300, 440)
        val width = AskPlace.width(pet, Side.RIGHT, area, 8, 8, 240, 360)
        assertTrue(width <= 304)
        val at = AskPlace.beside(pet, Side.RIGHT, width, 120, area, 8, 8)
        assertTrue(at.x >= 8 && at.x + width <= 312)
        assertEquals(32, AskPlace.lift(at.y, at.y, 500, 8, area, 8))
    }

    @Test fun imeUsesWindowOverlapAndRepeatedInsetsDoNotAccumulatePendingMoves() {
        val area = SafeArea(720, 1280, left = 0, top = 48, right = 0, bottom = 48)
        // Observed API 35: bar [679, 871], keyboard begins at 682; local inset is 189.
        assertEquals(474, AskPlace.lift(679, 679, 189, 16, area, 16))
        assertEquals(474, AskPlace.lift(679, 679, 189, 16, area, 16))
        assertEquals(474, AskPlace.lift(679, 474, 0, 16, area, 16))
        // Fully covered bars converge after the next measured inset, too.
        val first = AskPlace.lift(800, 800, 192, 16, area, 16)
        assertEquals(474, AskPlace.lift(800, first, 102, 16, area, 16))
    }
}
