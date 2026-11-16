package android.os

import java.nio.file.Files
import java.nio.file.Path

object Build {
    object VERSION { const val SDK_INT = 36 }
}

object Process {
    fun myPid(): Int = ProcessHandle.current().pid().toInt()
    fun myUid(): Int = Files.getAttribute(Path.of("/proc/self"), "unix:uid") as Int
}
