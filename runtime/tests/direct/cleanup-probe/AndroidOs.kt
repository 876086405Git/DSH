package android.system

import java.nio.file.AccessDeniedException
import java.nio.file.Files
import java.nio.file.Path

class Stat(val st_uid: Int)
class ErrnoException(val functionName: String, val errno: Int) : Exception(functionName)

/** JVM adapter: only the review's own child may be denied or signalled. */
object Os {
    @Volatile var beforeStat: ((Int?) -> Unit)? = null
    val denyStatPids = mutableSetOf<Int>()
    val permittedSignalPids = mutableSetOf<Int>()
    val denyOnce = mutableSetOf<Int>()
    val denyAfterSignal = mutableSetOf<Int>()
    val ignoreSignals = mutableSetOf<Int>()
    val foreignUid = mutableSetOf<Int>()
    val signalledPids = mutableListOf<Int>()
    var deniedReads = 0
    var sentSignals = 0

    fun stat(path: String): Stat {
        val pid = Path.of(path).fileName.toString().toIntOrNull()
        beforeStat?.invoke(pid)
        if (pid in denyStatPids || denyOnce.remove(pid)) {
            deniedReads++
            throw AccessDeniedException(path, null, "Independent simulated EACCES")
        }
        val uid = Files.getAttribute(Path.of(path), "unix:uid") as Int
        return Stat(if (pid in foreignUid) android.os.Process.myUid() + 1 else uid)
    }

    fun readlink(path: String): String = Files.readSymbolicLink(Path.of(path)).toString()

    fun kill(pid: Int, signal: Int) {
        check(pid in permittedSignalPids) { "The probe must never signal a foreign process" }
        sentSignals++
        signalledPids += pid
        if (pid in denyAfterSignal) denyStatPids += pid
        if (pid in ignoreSignals) return
        ProcessHandle.of(pid.toLong()).ifPresent {
            if (signal == OsConstants.SIGKILL) it.destroyForcibly() else it.destroy()
        }
    }
}

object OsConstants {
    const val ENOENT = 2
    const val ESRCH = 3
    const val SIGTERM = 15
    const val SIGQUIT = 3
    const val SIGKILL = 9
}
