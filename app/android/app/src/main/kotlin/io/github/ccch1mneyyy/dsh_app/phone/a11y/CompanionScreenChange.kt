package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.graphics.Bitmap
import android.graphics.Color
import kotlin.math.abs

/** A local visual-change trigger, not recognition or evidence of a safe page. */
internal class CompanionScreenChange {
    private var previous: ByteArray? = null
    private var readAt = Long.MIN_VALUE

    fun changed(grid: ByteArray, now: Long, textChanged: Boolean): Boolean {
        require(grid.size == WIDTH * HEIGHT)
        val old = previous
        previous = grid.copyOf()
        val difference = if (old == null) Int.MAX_VALUE else grid.indices.sumOf {
            abs((grid[it].toInt() and 255) - (old[it].toInt() and 255))
        }
        val due = old == null || textChanged || difference >= grid.size * 12 ||
            readAt == Long.MIN_VALUE || now < readAt || now - readAt >= 60000
        if (due) readAt = now
        return due
    }

    fun clear() { previous = null; readAt = Long.MIN_VALUE }

    companion object {
        const val WIDTH = 64
        const val HEIGHT = 36
        fun grid(bitmap: Bitmap): ByteArray = ByteArray(WIDTH * HEIGHT) { index ->
            val x = (index % WIDTH * bitmap.width / WIDTH).coerceAtMost(bitmap.width - 1)
            val y = (index / WIDTH * bitmap.height / HEIGHT).coerceAtMost(bitmap.height - 1)
            val c = bitmap.getPixel(x, y)
            ((77 * Color.red(c) + 150 * Color.green(c) + 29 * Color.blue(c)) shr 8).toByte()
        }
    }
}
