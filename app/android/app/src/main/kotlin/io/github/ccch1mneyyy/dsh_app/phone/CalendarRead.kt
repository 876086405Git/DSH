package io.github.ccch1mneyyy.dsh_app.phone

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract.Instances
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

/** Instances expands recurring events. All-day events use UTC calendar dates. */
internal fun readCalendar(context: Context, from: LocalDate, to: LocalDate, zone: ZoneId): SysResult {
    if (context.checkSelfPermission(Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED) {
        return calendarPermissionRequired()
    }
    val fromLocal = from.atStartOfDay(zone).toInstant().toEpochMilli()
    val toLocal = to.atStartOfDay(zone).toInstant().toEpochMilli()
    val fromUtc = from.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    val toUtc = to.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    val uri = Instances.CONTENT_URI.buildUpon().apply {
        ContentUris.appendId(this, minOf(fromLocal, fromUtc))
        ContentUris.appendId(this, maxOf(toLocal, toUtc))
    }.build()
    val columns = arrayOf(Instances.TITLE, Instances.BEGIN, Instances.END, Instances.ALL_DAY)
    val visibleRange = "${Instances.VISIBLE}=1 AND (" +
        "(${Instances.ALL_DAY}=0 AND ${Instances.END}>=? AND ${Instances.BEGIN}<?) OR " +
        "(${Instances.ALL_DAY}=1 AND ${Instances.END}>? AND ${Instances.BEGIN}<?))"
    val bounds = arrayOf(fromLocal.toString(), toLocal.toString(), fromUtc.toString(), toUtc.toString())
    val items = mutableListOf<Map<String, Any?>>()
    var more = false
    return try {
        val cursor = context.contentResolver.query(uri, columns, visibleRange, bounds, "${Instances.BEGIN} ASC")
            ?: return calendarUnavailable()
        cursor.use {
            while (it.moveToNext()) {
                val start = it.getLong(1)
                val end = it.getLong(2)
                val allDay = it.getInt(3) != 0
                // An event ending exactly at midnight belongs to the preceding day.
                if (!allDay && end == fromLocal && start < fromLocal) continue
                if (items.size == 50) {
                    more = true
                    break
                }
                items += mapOf(
                    "title" to it.getString(0)?.take(200).orEmpty(),
                    "start" to calendarTime(start, allDay, zone),
                    "end" to calendarTime(end, allDay, zone),
                    "allDay" to allDay,
                )
            }
        }
        SysResult(true, Json.write(mapOf(
            "status" to "verified",
            "startDate" to from.toString(),
            "endDateExclusive" to to.toString(),
            "timeZone" to zone.id,
            "events" to items,
            "truncated" to more,
        )))
    } catch (_: SecurityException) {
        calendarPermissionRequired()
    } catch (_: IllegalArgumentException) {
        calendarUnavailable()
    }
}

private fun calendarTime(millis: Long, allDay: Boolean, zone: ZoneId): String =
    if (allDay) Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate().toString()
    else Instant.ofEpochMilli(millis).atZone(zone).toOffsetDateTime().toString()

private fun calendarPermissionRequired() = SysResult(false,
    "CALENDAR_PERMISSION_REQUIRED：在小屋 → 系统数字助理 → 允许读取日历，或从 Android 应用权限授予日历访问。") // l10n:keep agent tool result

private fun calendarUnavailable() = SysResult(false,
    "CALENDAR_UNAVAILABLE：没有可读取的 Android 日历提供程序。") // l10n:keep agent tool result
