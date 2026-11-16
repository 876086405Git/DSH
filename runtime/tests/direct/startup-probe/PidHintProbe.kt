package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** A hidden, recycled pidfile number is not a captured runtime identity. */
fun main(args: Array<String>) {
    check(AndroidProcess.myUid() != 0)
    val case = args[1]
    check(case in setOf("stale-hint", "captured-hidden", "visible-owned"))
    val root = Files.createTempDirectory(File(args[0]).toPath(), "pid-hint-").toFile()
    // Outside Linux's PID range: absent from enumeration, but direct lookup is
    // faulted like Android hiding a PID that has been reused by another UID.
    val hidden = 2_000_000_000
    val pidFile = File(root, "tmp/dsh-web.pid").apply {
        parentFile.mkdirs()
        writeText("$hidden\n")
    }
    val marker = File(root, "launched.txt")
    val launcher = File(root, "fixture-launcher").apply {
        writeText("#!/bin/sh\nprintf 'started\\n' >> '${marker.path}'\n")
        check(setExecutable(true, true))
    }
    val done = CountDownLatch(1)
    val runtime = DshProcess(Context(root), RuntimeManifest(launchArgv = listOf(
        launcher.path, "/usr/bin/env", "-i", "{GUEST_ENV}", "startup-probe-command",
    )), root, object : DshProcess.Listener {
        override fun onLog(line: String, stream: String, storageLine: String) { println(line) }
        override fun onReady(source: DshProcess, baseUrl: String, token: String) {}
        override fun onStartupFailure(source: DshProcess) {}
        override fun onExit(source: DshProcess, code: Int, expected: Boolean) { done.countDown() }
    })
    val state = RuntimeProcessOwnership.cleanupState(root.canonicalPath, AndroidProcess.myUid())
    val child = if (case != "visible-owned") null else ProcessBuilder("/bin/sleep", "45")
        .directory(root).apply { environment()["DSH_GO_RUNTIME_ROOT"] = root.canonicalPath }.start()
    child?.let { Os.permittedSignalPids += it.pid().toInt() }
    // Keep the hidden-PID fault and our real child visible, not host-runner daemons.
    Os.beforeStat = { observed ->
        if (observed != null && observed != hidden && observed != child?.pid()?.toInt()) Os.foreignUid += observed
    }
    Os.denyStatPids += hidden
    if (case == "captured-hidden") synchronized(state) { state.known[hidden] = "100" }
    try {
        val cleanup = runtime.reapStrays()
        if (case == "captured-hidden") {
            check(!cleanup.complete && cleanup.ownedRemaining)
            check(Os.deniedReads > 0 && Os.sentSignals == 0)
            val failure = runCatching { runtime.start(emptyMap()) }.exceptionOrNull()
            check(failure?.message == "runtime cleanup incomplete; stop the engine and retry")
            check(pidFile.isFile && !marker.exists())
        } else {
            check(cleanup.complete && !cleanup.ownedRemaining) { "A bare stale PID blocked strict cleanup" }
            check(Os.deniedReads == 0) { "An uncaptured hidden PID was queried" }
            check(Os.sentSignals == if (child == null) 0 else Os.signalledPids.size)
            child?.let {
                check(it.waitFor(2, TimeUnit.SECONDS))
                check(Os.signalledPids.isNotEmpty() && Os.signalledPids.all { pid -> pid == it.pid().toInt() })
            }
            // Exercise start as well: the stale file is removed only after strict cleanup.
            runtime.start(emptyMap())
            check(done.await(12, TimeUnit.SECONDS))
            check(runtime.awaitExit(1000))
            check(!pidFile.exists() && marker.readLines() == listOf("started"))
        }
        println("{\"case\":\"$case\",\"passed\":true}")
    } finally {
        Os.beforeStat = null
        synchronized(state) { state.known.remove(hidden) }
        Os.denyStatPids -= hidden
        child?.let { if (it.isAlive) it.destroyForcibly(); it.waitFor() }
        runtime.stop()
        runtime.awaitExit(12000)
        root.deleteRecursively()
    }
}
