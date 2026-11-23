package io.github.ccch1mneyyy.dsh_app.companion

import android.content.Context
import android.content.SharedPreferences
import java.time.LocalDate

/** Calendar-day counters and a package's last observed system post time bound replay across process death. */
internal class NoticeStatistics(context: Context) {
    private val prefs = context.getSharedPreferences("companion_notice_counts", Context.MODE_PRIVATE)
    private var lastPruned: Long? = null
    private val previousProcess = prefs.all.filterKeys { "/last/" in it }.mapValues { it.value as Long }.toMutableMap()

    private fun today(): Long {
        val day = LocalDate.now().toEpochDay()
        if (day != lastPruned) {
            val edit = prefs.edit()
            for (key in prefs.all.keys) {
                val entryDay = key.substringBefore('/').toLong()
                if (entryDay !in day - 6..day) {
                    edit.remove(key)
                    previousProcess.remove(key)
                }
            }
            edit.apply()
            lastPruned = day
        }
        return day
    }

    private fun increment(edit: SharedPreferences.Editor, key: String, count: Int) {
        if (count > 0) edit.putInt(key, prefs.getInt(key, 0) + count)
    }

    fun observed(pkg: String, postedMs: Long, replay: Boolean) {
        val today = today()
        val day = java.time.Instant.ofEpochMilli(postedMs).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toEpochDay()
        if (day !in today - 6..today) return
        val last = "$day/last/$pkg"
        if (replay && postedMs <= (previousProcess[last] ?: Long.MIN_VALUE)) return
        val edit = prefs.edit()
        if (postedMs > prefs.getLong(last, Long.MIN_VALUE)) edit.putLong(last, postedMs)
        increment(edit, "$day/pkg/$pkg", 1)
        edit.apply()
    }

    fun record(received: Int = 0, judged: Int = 0, said: Int = 0) {
        val day = today()
        val edit = prefs.edit()
        increment(edit, "$day/received", received)
        increment(edit, "$day/judged", judged)
        increment(edit, "$day/said", said)
        edit.apply()
    }

    fun status(): Map<String, Int> {
        val day = today()
        return listOf("received", "judged", "said").associateWith { prefs.getInt("$day/$it", 0) }
    }

    fun recent(): Map<String, Int> {
        today()
        val sums = mutableMapOf<String, Int>()
        for ((key, value) in prefs.all) {
            val pkg = key.substringAfter("/pkg/", "")
            if (pkg.isNotEmpty()) sums[pkg] = (sums[pkg] ?: 0) + (value as Int)
        }
        return sums
    }

    fun clearRecent() {
        val edit = prefs.edit()
        previousProcess.clear()
        prefs.all.keys.filter { "/pkg/" in it || "/last/" in it }.forEach { edit.remove(it) }
        edit.apply()
    }
}
