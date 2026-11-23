package io.github.ccch1mneyyy.dsh_app.companion

import org.junit.Assert.*
import org.junit.Test

class NoticeInboxTest {
    private val open = NoticeAccess(true, true, true)

    @Test fun packageMustBeSelectedAndAllThreeSystemGatesMustBeOpen() {
        for (access in listOf(open.copy(enabled = false), open.copy(granted = false), open.copy(unlocked = false))) {
            assertFalse(access.reads("remember"))
        }
        assertFalse(open.reads("off"))
        assertTrue(open.reads("glance"))
        assertTrue(open.reads("remember"))
    }

    @Test fun lockDisconnectsAndUnlockRequestsARebindOnlyIfStillAuthorized() {
        assertEquals(NoticeBinding.UNBIND, noticeBinding(open.copy(unlocked = false), true))
        assertEquals(NoticeBinding.KEEP, noticeBinding(open.copy(unlocked = false), false))
        assertEquals(NoticeBinding.REBIND, noticeBinding(open, false))
        assertEquals(NoticeBinding.KEEP, noticeBinding(open.copy(granted = false), false))
        assertEquals(NoticeBinding.KEEP, noticeBinding(open, true))
    }

    @Test fun lockDropsPendingRawTextAndRebuildsOnlyUnconsumedActiveVersions() {
        val inbox = NoticeInbox()
        val posts = NoticePosts()
        for (id in listOf("pending", "consumed", "withdrawn")) {
            assertTrue(posts.observe(id, 90))
            inbox.add("chat", id, 100, 90, "initial")
            assertTrue(posts.markCaptured(id))
        }
        inbox.take("chat", listOf("consumed"))
        posts.forgetPending(inbox.keys())
        inbox.clear()
        for (activeKey in listOf("pending", "consumed")) {
            assertFalse(posts.observe(activeKey, 90))
            if (!posts.captured(activeKey)) {
                inbox.add("chat", activeKey, 110, 90, "restored")
                assertFalse(posts.markCaptured(activeKey))
            }
        }
        assertEquals(listOf("pending"), inbox.keys())
        assertTrue(posts.observe("consumed", 120))
        assertFalse(posts.captured("consumed"))
    }

    @Test fun filtersOngoingServiceAndSystemCategories() {
        for (category in listOf("transport", "call", "missed_call", "alarm", "navigation", "stopwatch", "timer", "progress", "service")) {
            assertFalse(NoticeFilter.acceptsCategory(category, false, false))
        }
        assertFalse(NoticeFilter.acceptsCategory("msg", true, false))
        assertFalse(NoticeFilter.acceptsCategory("msg", false, true))
        assertTrue(NoticeFilter.acceptsCategory("msg", false, false))
    }

    @Test fun dropsSecretsInAnyVisibleFieldBeforeTruncationOrControlCharacterCleanup() {
        for (hint in listOf("验\u200b证码", "pass\nword", "OTP", "code is 012345", "verification code")) {
            assertNull(NoticeFilter.segment(listOf("x".repeat(550), hint)))
        }
    }

    @Test fun traditionalVerificationCodeIsDroppedBeforeTheInbox() {
        assertNull(NoticeFilter.segment(listOf("您的驗證碼為 １２３４５６")))
        // Split across title and text, each harmless alone.
        assertNull(NoticeFilter.segment(listOf("Your code", "123456")))
        assertNull(NoticeFilter.segment(listOf("Your code is 123 456")))
        assertNull(NoticeFilter.segment(listOf("Your code is A1B2C3")))
        assertEquals("Promo code SPRING", NoticeFilter.segment(listOf("Promo code SPRING")))
        // A date near 「code」 is not a code.
        assertEquals("Dress code for 11-24 is casual", NoticeFilter.segment(listOf("Dress code for 11-24 is casual")))
    }

    @Test fun traditionalPasswordIsDroppedEvenWithAnInvisibleSeparator() {
        assertNull(NoticeFilter.segment(listOf("臨時密\u2060碼：example")))
    }

    @Test fun deduplicatesVisibleFieldsAndTruncatesWithoutSplittingUnicode() {
        assertEquals("hello world · mail", NoticeFilter.segment(listOf(" hello\nworld", "hello world", "\u200bmail")))
        val emoji = "🌦".repeat(520)
        assertEquals("🌦".repeat(500), NoticeFilter.segment(listOf(emoji)))
    }

    @Test fun sameKeyKeepsTenLatestDistinctConsecutiveSegmentsAndItsFirstQueueTime() {
        val inbox = NoticeInbox()
        repeat(12) { inbox.add("chat", "key", it.toLong(), it.toLong(), "message $it", "person$it") }
        assertFalse(inbox.add("chat", "key", 22, 22, "message 11", "person11"))
        assertEquals(0L, inbox.pending().single()["atMs"])
        assertTrue(inbox.take("other", listOf("key")).isEmpty())
        val item = inbox.take("chat", listOf("key")).single()
        assertEquals((2..11).map { "message $it" }, item.segments.map { it.text })
        assertEquals(2L, item.segments.first().atMs)
        assertEquals("person2", item.segments.first().personId)
        assertEquals(11L, item.segments.last().atMs)
        assertEquals("person11", item.segments.last().personId)
        assertTrue(inbox.pending().isEmpty())
    }

    @Test fun evictsOldestAtCapacityAndDropsOnlyTheChangedPackage() {
        val inbox = NoticeInbox()
        repeat(201) { inbox.add(if (it == 1) "mail" else "chat", "$it", it.toLong(), it.toLong(), "message") }
        assertEquals(200, inbox.pending().size)
        assertTrue(inbox.take("chat", listOf("0")).isEmpty())
        inbox.clear("chat")
        assertEquals(listOf("1"), inbox.keys())
    }

    @Test fun opaqueIdsAreStableWithinAnInstallAndScopedByDomain() {
        val ids = NoticeIds(ByteArray(32) { 1 })
        val key = ids.digest("key", "sample")
        assertTrue(key.matches(Regex("[0-9a-f]{64}")))
        assertEquals(key, ids.digest("key", "sample"))
        assertNotEquals(key, ids.digest("conversation:chat", "sample"))
        assertNotEquals(key, NoticeIds(ByteArray(32) { 2 }).digest("key", "sample"))
    }
}
