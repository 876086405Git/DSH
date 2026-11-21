package io.github.ccch1mneyyy.dsh_app.companion

import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId

/** 提醒采用目标日的实际时区规则，不用原话当日的临时偏移推算未来。 */
internal object CompanionReminderTime {
    fun observe(): Map<String, Any> {
        val now = System.currentTimeMillis()
        val zone = ZoneId.systemDefault()
        return mapOf(
            "utcMs" to now,
            "zoneId" to zone.id,
            "offsetSeconds" to zone.rules.getOffset(Instant.ofEpochMilli(now)).totalSeconds,
        )
    }

    fun resolve(
        localDate: String,
        localTime: String,
        zoneId: String,
        selectedOffsetSeconds: Int? = null,
    ): Map<String, Any> {
        val local = LocalDateTime.of(LocalDate.parse(localDate), LocalTime.parse(localTime))
        val zone = ZoneId.of(zoneId)
        val offsets = zone.rules.getValidOffsets(local)
        if (selectedOffsetSeconds != null) {
            require(offsets.any { it.totalSeconds == selectedOffsetSeconds }) {
                "Selected offset is not valid for this local time"
            }
        }
        val selected = if (selectedOffsetSeconds == null) offsets
            else offsets.filter { it.totalSeconds == selectedOffsetSeconds }
        val moments = selected.map { offset ->
            mapOf("epochMs" to local.toInstant(offset).toEpochMilli(), "offsetSeconds" to offset.totalSeconds)
        }
        return mapOf(
            "kind" to when (moments.size) { 0 -> "gap"; 1 -> "unique"; else -> "overlap" },
            "localDate" to local.toLocalDate().toString(),
            "localTime" to local.toLocalTime().toString(),
            "zoneId" to zone.id,
            "moments" to moments,
        )
    }
}
