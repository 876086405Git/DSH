package io.github.ccch1mneyyy.dsh_app.companion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Instant

class CompanionReminderTimeTest {
    private data class ClockCase(val date: String, val resumedMs: Long, val dueMs: Long, val minutes: Long)
    @Suppress("UNCHECKED_CAST")
    private fun moments(result: Map<String, Any>): List<Map<String, Number>> =
        result["moments"] as List<Map<String, Number>>

    @Test fun twoValid0310TimesKeepTheirReal80And20MinuteIntervals() {
        for (sample in listOf(
            ClockCase("2026-03-07", 1772877000000L, 1772881800000L, 80L),
            ClockCase("2026-03-08", 1772963400000L, 1772964600000L, 20L),
        )) {
            val result = CompanionReminderTime.resolve(sample.date, "03:10", "America/Los_Angeles")
            assertEquals("unique", result["kind"])
            val actual = moments(result).single()["epochMs"]!!.toLong()
            assertEquals(sample.dueMs, actual)
            assertEquals(sample.minutes, (actual - sample.resumedMs) / 60_000)
        }
    }

    @Test fun springGapDoesNotSilentlyMoveTheReminderToAnotherTime() {
        val result = CompanionReminderTime.resolve("2026-03-08", "02:30", "America/Los_Angeles")
        assertEquals("gap", result["kind"])
        assertEquals(emptyList<Map<String, Number>>(), moments(result))
    }

    @Test fun fallOverlapKeepsBothInstantsUntilAnActualOffsetIsChosen() {
        val result = CompanionReminderTime.resolve("2026-11-01", "01:30", "America/Los_Angeles")
        assertEquals("overlap", result["kind"])
        assertEquals(listOf(Instant.parse("2026-11-01T08:30:00Z").toEpochMilli(),
            Instant.parse("2026-11-01T09:30:00Z").toEpochMilli()), moments(result).map { it["epochMs"]!!.toLong() })
        val chosen = CompanionReminderTime.resolve("2026-11-01", "01:30", "America/Los_Angeles", -8 * 3600)
        assertEquals("unique", chosen["kind"])
        assertEquals(Instant.parse("2026-11-01T09:30:00Z").toEpochMilli(), moments(chosen).single()["epochMs"]!!.toLong())
        assertThrows(IllegalArgumentException::class.java) {
            CompanionReminderTime.resolve("2026-11-01", "01:30", "America/Los_Angeles", 8 * 3600)
        }
    }

    @Test fun futureDateUsesItsOwnRulesWhileExplicitFixedOffsetStaysFixed() {
        val summer = CompanionReminderTime.resolve("2027-07-01", "08:00", "America/Los_Angeles")
        assertEquals(-7 * 3600, moments(summer).single()["offsetSeconds"]!!.toInt())
        val fixed = CompanionReminderTime.resolve("2027-07-01", "08:00", "-08:00")
        assertEquals(-8 * 3600, moments(fixed).single()["offsetSeconds"]!!.toInt())
        assertEquals(3_600_000L, moments(fixed).single()["epochMs"]!!.toLong() -
            moments(summer).single()["epochMs"]!!.toLong())
    }
}
