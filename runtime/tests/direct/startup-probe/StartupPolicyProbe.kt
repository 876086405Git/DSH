package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import java.io.File
import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Actual start/cleanup methods; only the child launcher and Android API edges are controlled. */
fun main(args: Array<String>) {
    check(AndroidProcess.myUid() != 0) { "use a real non-root UID" }
    val base = File(args[0])
    val case = args[1]
    val root = Files.createTempDirectory(base.toPath(), "runtime-").toFile()
    val other = Files.createTempDirectory(base.toPath(), "other-").toFile()
    val owned = case in setOf("default-owned", "default-captured-unknown", "default-owned-reaped")
    val denied = case.endsWith("unknown") && case != "default-captured-unknown"
    val requestedDirect = case in setOf("direct-unknown", "safe-unknown", "l2s-fallback-unknown")
    val safe = case == "safe-unknown"
    val shouldLaunch = case !in setOf("direct-unknown", "default-owned", "default-captured-unknown")
    val expectsAlias = case in setOf("prior-direct-alias", "carried-direct-alias")
    if (case == "carried-direct-alias") {
        File(root, "root").mkdirs()
        File(root, "root/.dsh-go-direct-path-alias").writeText("v1\n${root.canonicalPath}\n")
    }
    if (case == "l2s-fallback-unknown") File(root, "root/.l2s").apply { mkdirs() }.resolve("kept").writeText("fixture")
    if (case == "prior-direct-alias" || case == "symlink-config-no-alias") {
        val config = File(root, "opt/dsh-app/direct/config.json")
        config.parentFile.mkdirs()
        if (case == "prior-direct-alias") config.writeText("{\"schema\":2}")
        else Files.createSymbolicLink(config.toPath(), File(other, "untrusted.json").apply { writeText("{}") }.toPath())
    }
    val recordedArgs = File(root, "actual-argv.txt")
    val launcher = File(root, "fixture-launcher").apply {
        writeText("#!/bin/sh\n: > '${recordedArgs.path}'\nfor arg in \"\$@\"; do printf '%s\\n' \"\$arg\" >> '${recordedArgs.path}'; done\n")
        check(setExecutable(true, true))
    }
    val logs = Collections.synchronizedList(mutableListOf<String>())
    val methods = mutableListOf<Boolean>()
    val exits = Collections.synchronizedList(mutableListOf<Int>())
    val done = CountDownLatch(1)
    val child = ProcessBuilder("/bin/sleep", "45").directory(if (owned) root else other).apply {
        if (owned) environment()["DSH_GO_RUNTIME_ROOT"] = root.canonicalPath
        else environment().remove("DSH_GO_RUNTIME_ROOT")
    }.start()
    val pid = child.pid().toInt()
    Os.permittedSignalPids += pid // only this test's own child may ever receive a signal
    // Host-runner daemons are not part of this app fixture's UID view.
    Os.beforeStat = { observed -> if (observed != null && observed != pid) Os.foreignUid += observed }
    if (denied) Os.denyStatPids += pid
    if (case in setOf("default-owned", "default-captured-unknown")) Os.ignoreSignals += pid
    if (case == "default-captured-unknown") Os.denyAfterSignal += pid
    val alias = "${root.canonicalPath}:${root.canonicalPath}"
    val runtime = DshProcess(Context(root), RuntimeManifest(launchArgv = listOf(
        launcher.path, "-b", "{ROOTFS}:{ROOTFS}", "-b", "/fixture-storage:/mnt/storage",
        "/usr/bin/env", "-i", "{GUEST_ENV}", "startup-probe-command"
    )), root, object : DshProcess.Listener {
        override fun onLog(line: String, stream: String, storageLine: String) { logs += line }
        override fun onReady(source: DshProcess, baseUrl: String, token: String) {}
        override fun onStartupFailure(source: DshProcess) {}
        override fun onExit(source: DshProcess, code: Int, expected: Boolean) { exits += code; done.countDown() }
    })
    try {
        val failure = runCatching {
            runtime.start(emptyMap(), safe = safe, directEngine = requestedDirect, onLaunchMethod = { methods += it })
        }.exceptionOrNull()
        if (failure == null) {
            check(done.await(12, TimeUnit.SECONDS)) { "launcher did not exit" }
            runtime.awaitExit(1000)
        }
        val captured = if (recordedArgs.isFile) recordedArgs.readLines() else emptyList()
        val cleanup = runtime.killStrays()
        val errors = mutableListOf<String>()
        fun expect(value: Boolean, message: String) { if (!value) errors += message }
        expect(runtime.executionMode == null, "an exited or rejected launch reported a current process")
        expect(runtime.launchDiagnostics.spawned == (failure == null), "spawn fact did not match the actual fixture child")
        expect(runtime.launchDiagnostics.selectedMode == if (case == "direct-unknown") "direct" else "proot", "selected method mismatch")
        if (case == "safe-unknown") expect(runtime.launchDiagnostics.fallbackReason == "safeRecovery", "safe recovery reason was lost")
        if (case == "l2s-fallback-unknown") expect(runtime.launchDiagnostics.fallbackReason == "incompatibleFiles", "incompatible files reason was lost")
        expect((failure == null) == shouldLaunch, "launch policy mismatch: $failure")
        if (shouldLaunch && failure == null) {
            expect(methods == listOf(false), "actual PRoot mode was not reported")
            expect(exits == listOf(0), "fixture launch did not exit successfully")
            expect(captured.contains(alias) == expectsAlias, "unexpected physical rootfs alias")
            expect(captured.contains("/fixture-storage:/mnt/storage"), "caller storage bind changed")
            if (case == "l2s-fallback-unknown") expect(runtime.directFallbackReason == "incompatibleFiles", "fallback lost its reason")
        }
        if (!shouldLaunch) {
            val expectedFailure = if (case == "direct-unknown") "direct engine: runtimeUpdateRequired"
                else "runtime cleanup incomplete; stop the engine and retry"
            expect(failure?.message == expectedFailure, "wrong refusal: $failure")
            expect(methods.isEmpty() && captured.isEmpty(), "a blocked launch reached its callback or child")
        }
        if (!owned) expect(child.isAlive && Os.sentSignals == 0, "unrelated process was signalled")
        else expect(Os.sentSignals > 0 && Os.signalledPids.all { it == pid }, "owned tree was not handled precisely")
        expect(cleanup == !(denied || case in setOf("default-owned", "default-captured-unknown")), "killStrays misreported observation/ownership")
        if (case == "default-owned-reaped") expect(!child.isAlive, "owned process survived cleanup")
        fun quote(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""
        println("{" + listOf(
            "\"case\":${quote(case)}", "\"uid\":${AndroidProcess.myUid()}",
            "\"launched\":${failure == null}", "\"cleanupComplete\":$cleanup",
            "\"signals\":${Os.sentSignals}", "\"deniedReads\":${Os.deniedReads}",
            "\"aliasPresent\":${captured.contains(alias)}", "\"childAlive\":${child.isAlive}",
            "\"errors\":[${errors.joinToString(",", transform = ::quote)}]",
            "\"logs\":[${logs.joinToString(",", transform = ::quote)}]"
        ).joinToString(",") + "}")
        check(errors.isEmpty()) { errors.joinToString("; ") }
    } finally {
        Os.beforeStat = null
        Os.denyStatPids -= pid
        Os.ignoreSignals -= pid
        Os.denyAfterSignal -= pid
        if (child.isAlive) child.destroyForcibly()
        child.waitFor()
        runtime.stop()
        runtime.awaitExit(12000)
        root.deleteRecursively()
        other.deleteRecursively()
    }
}
