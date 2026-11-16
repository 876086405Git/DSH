package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Real launch planning/spawn with harmless executables, not a guest engine. */
fun main(args: Array<String>) {
    check(AndroidProcess.myUid() != 0)
    val case = args[1]
    check(case in setOf("direct-ambient", "tawc-ambient", "direct-captured", "tawc-captured", "proot-links-ambient"))
    val tawc = case.startsWith("tawc-")
    val captured = case.endsWith("-captured")
    val links = case == "proot-links-ambient"
    val base = Files.createTempDirectory(File(args[0]).toPath(), "observation-").toFile()
    val root = File(base, "rootfs").apply { mkdirs() }
    File(root, "root").mkdirs()
    val other = File(base, "other").apply { mkdirs() }
    val marker = File(base, "launched.txt")
    fun executable(file: File) {
        file.parentFile.mkdirs()
        file.writeText("#!/bin/sh\nprintf 'started\\n' >> '${marker.path}'\n")
        check(file.setExecutable(true, true))
    }
    val context = Context(root)
    executable(File(context.applicationInfo.nativeLibraryDir, "libproot.so"))
    executable(File(context.applicationInfo.nativeLibraryDir, TawcrootLaunch.LIBRARY))
    executable(File(root, DirectLaunch.loaderPath("x86_64")))
    executable(File(root, "opt/node/bin/node"))
    for (name in listOf("preload.mjs", "dns.mjs", "modules.mjs", "native-addons.json")) {
        File(root, "opt/dsh-go/direct/$name").apply { parentFile.mkdirs(); writeText("fixture") }
    }
    // Minimal static ELF64 metadata for the real DirectLaunch planner.
    File(root, "opt/dsh/node_modules/@vscode/ripgrep-linux-x64/bin/rg").apply {
        parentFile.mkdirs()
        writeBytes(ByteArray(120).also {
            it[0] = 0x7f; it[1] = 69; it[2] = 76; it[3] = 70; it[4] = 2; it[5] = 1
            it[32] = 64; it[54] = 56; it[56] = 1; it[64] = 1
        })
    }
    val binds = listOf("/dev", "/dev/urandom:/dev/random", "/proc", "/proc/self/fd:/dev/fd",
        "/proc/self/fd/0:/dev/stdin", "/proc/self/fd/1:/dev/stdout", "/proc/self/fd/2:/dev/stderr",
        "/sys", "{ROOTFS}/var/lib/dsh-app/empty:/sys/fs/selinux", "{ROOTFS}/var/lib/dsh-app/shm:/dev/shm",
        "/system", "/apex")
    val argv = listOf("{NATIVE_LIB_DIR}/libproot.so", "--kill-on-exit", "--link2symlink", "--sysvipc", "-L", "-0",
        "--rootfs={ROOTFS}", "--cwd=/root") + binds.flatMap { listOf("-b", it) } +
        listOf("/usr/bin/env", "-i", "{GUEST_ENV}", "/bin/sh", "-c",
            "echo \$\$ > /tmp/dsh-web.pid; exec /usr/local/bin/dsh web --host 127.0.0.1 --port {PORT} --no-open")
    val done = CountDownLatch(1)
    val runtime = DshProcess(context, RuntimeManifest(launchArgv = argv), root, object : DshProcess.Listener {
        override fun onLog(line: String, stream: String, storageLine: String) { println(line) }
        override fun onReady(source: DshProcess, baseUrl: String, token: String) {}
        override fun onStartupFailure(source: DshProcess) {}
        override fun onExit(source: DshProcess, code: Int, expected: Boolean) { check(code == 0); done.countDown() }
    })
    val child = ProcessBuilder("/bin/sleep", "45").directory(if (captured) root else other).apply {
        if (captured) environment()["DSH_GO_RUNTIME_ROOT"] = root.canonicalPath
        else environment().remove("DSH_GO_RUNTIME_ROOT")
    }.start()
    val pid = child.pid().toInt()
    Os.permittedSignalPids += pid
    // The app fixture owns this child, not the CI runner's background services.
    Os.beforeStat = { observed -> if (observed != null && observed != pid) Os.foreignUid += observed }
    if (captured) {
        Os.ignoreSignals += pid
        Os.denyAfterSignal += pid
    } else Os.denyStatPids += pid
    val pending = File(base, "tawcroot/link").apply { if (links) mkdirs() }
    val sentinel = File(pending, "kept").apply { if (links) writeText("unchanged") }
    var method: Boolean? = null
    try {
        if (captured) check(runtime.reapStrays(allowObservationGap = true).ownedRemaining)
        val failure = runCatching {
            runtime.start(emptyMap(), directEngine = !tawc && !links, tawcEngine = tawc,
                onLaunchMethod = { method = it })
        }.exceptionOrNull()
        if (captured || links) {
            check(failure?.message == "runtime cleanup incomplete; stop the engine and retry") { "Unexpected failure: $failure" }
            check(!marker.exists() && method == null && child.isAlive)
            if (links) check(sentinel.readText() == "unchanged")
        } else {
            check(failure == null) { "Ambient observation blocked launch: $failure" }
            check(done.await(12, TimeUnit.SECONDS) && runtime.awaitExit(1000))
            check(marker.readLines() == listOf("started"))
            check(method == !tawc && runtime.tawc == tawc && runtime.direct == !tawc)
            check(child.isAlive && Os.sentSignals == 0)
            check(!runtime.killStrays()) { "Incomplete observation was falsely reported complete" }
        }
        println("{\"case\":\"$case\",\"passed\":true}")
    } finally {
        Os.beforeStat = null
        Os.denyStatPids -= pid
        Os.ignoreSignals -= pid
        Os.denyAfterSignal -= pid
        if (child.isAlive) child.destroyForcibly()
        child.waitFor()
        runtime.stop()
        runtime.awaitExit(12000)
        base.deleteRecursively()
    }
}
