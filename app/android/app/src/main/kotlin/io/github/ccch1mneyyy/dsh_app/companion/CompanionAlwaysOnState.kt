package io.github.ccch1mneyyy.dsh_app.companion

import android.content.Context
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

/** Only the explicit switch and its generation cross processes. No transcript or task journal. */
internal object CompanionAlwaysOnState {
    data class Value(val enabled: Boolean, val epoch: Long)

    @Synchronized
    private fun <T> locked(context: Context, action: (AtomicFile) -> T): T {
        val directory = File(context.noBackupFilesDir, "companion-resident").also { it.mkdirs() }
        return RandomAccessFile(File(directory, "switch.lock"), "rw").use { lock ->
            lock.channel.lock().use { action(AtomicFile(File(directory, "switch.json"))) }
        }
    }

    private fun read(file: AtomicFile): Value = try {
        val value = JSONObject(file.openRead().bufferedReader(Charsets.UTF_8).use { it.readText() })
        Value(value.optBoolean("enabled", false), value.optLong("epoch", 0))
    } catch (_: java.io.FileNotFoundException) {
        Value(false, 0)
    }

    fun read(context: Context): Value = locked(context, ::read)

    /** A delivery and a switch change cannot pass each other across processes. */
    fun <T> withValue(context: Context, action: (Value) -> T): T = locked(context) { action(read(it)) }

    fun set(context: Context, enabled: Boolean): Value = locked(context) { file ->
        val old = read(file)
        if (old.enabled == enabled) old else {
            val value = Value(enabled, old.epoch + 1)
            val stream = file.startWrite()
            try {
                stream.write(JSONObject().put("enabled", value.enabled).put("epoch", value.epoch)
                    .toString().toByteArray(Charsets.UTF_8))
                file.finishWrite(stream)
            } catch (error: Throwable) {
                file.failWrite(stream)
                throw error
            }
            value
        }
    }
}
