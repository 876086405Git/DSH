package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files

/**
 * The default launch where available: the same prepared PRoot command, run by tawc's
 * libtawcroot.so (seccomp + SIGSYS path translation, no ptrace). The guest tree
 * and command are unchanged; hard links live in a store next to the rootfs
 * ([TawcrootLinks] turns them back into files before PRoot or Direct run).
 */
object TawcrootLaunch {
    const val LIBRARY = "libtawcroot.so"

    /** Fallback reasons. */
    const val FAILED = "tawcrootFailed"
    const val UNSUPPORTED = "tawcrootUnsupported"
    const val NOT_BUNDLED = "tawcrootNotBundled"
    const val API_TOO_OLD = "tawcrootApiTooOld"

    data class DevView(val directory: String, val links: Map<String, String>)

    /** Values may contain prepared guest credentials; do not log [environment]. */
    data class Plan(val argv: List<String>, val environment: Map<String, String>, val cwd: String, val devView: DevView)

    class Unsupported(reason: String) : IllegalArgumentException("tawcroot: unsupported launch ($reason)")

    fun unavailable(nativeLibraryDir: String, apiLevel: Int): String? = when {
        apiLevel < 29 -> API_TOO_OLD
        !File(nativeLibraryDir, LIBRARY).isFile -> NOT_BUNDLED
        else -> null
    }

    // Device nodes an Android app can stat but not list (/dev is not readable there).
    private val DEVICES = listOf("null", "zero", "full", "urandom", "tty", "ptmx", "pts")

    /**
     * Maps the prepared PRoot command ([prootArgv], placeholders already expanded) onto
     * tawcroot. Only the runtime's fixed binds, the rootfs alias and phone storage are
     * understood; anything else is [Unsupported] and the caller stays on PRoot.
     */
    fun prepare(rootfs: String, nativeLibraryDir: String, prootArgv: List<String>, hostEnvironment: Map<String, String>): Plan {
        if (!absolutePath(rootfs) || rootfs.lastIndexOf('/') == 0 || !absolutePath(nativeLibraryDir)) throw Unsupported("path")
        val prefix = listOf(
            "$nativeLibraryDir/libproot.so", "--kill-on-exit", "--link2symlink",
            "--sysvipc", "-L", "-0", "--rootfs=$rootfs", "--cwd=/root",
        )
        if (prootArgv.take(prefix.size) != prefix) throw Unsupported("prefix")
        val envAt = prootArgv.indexOf("/usr/bin/env")
        if (envAt < prefix.size || prootArgv.getOrNull(envAt + 1) != "-i" || envAt + 2 >= prootArgv.size) throw Unsupported("command")

        val runtimeDir = rootfs.substringBeforeLast('/')
        // tawcroot binds directories only: /dev becomes a directory of links, file binds become links in it.
        val view = DevView("$runtimeDir/dev-view", linkedMapOf<String, String>().apply {
            DEVICES.filter { File("/dev", it).exists() }.forEach { put(it, "/dev/$it") }
            put("random", "/dev/urandom")
            // Resolved in the calling process, not when tawcroot opens bind sources.
            put("fd", "/proc/self/fd")
            put("stdin", "/proc/self/fd/0")
            put("stdout", "/proc/self/fd/1")
            put("stderr", "/proc/self/fd/2")
        })
        val fixed = linkedMapOf<String, String?>(
            "/dev" to "${view.directory}:/dev",
            "/dev/urandom:/dev/random" to null,
            "/proc" to "/proc:/proc",
            "/proc/self/fd:/dev/fd" to null,
            "/proc/self/fd/0:/dev/stdin" to null,
            "/proc/self/fd/1:/dev/stdout" to null,
            "/proc/self/fd/2:/dev/stderr" to null,
            "/sys" to "/sys:/sys",
            "$rootfs/var/lib/dsh-app/empty:/sys/fs/selinux" to "$rootfs/var/lib/dsh-app/empty:/sys/fs/selinux",
            "$rootfs/var/lib/dsh-app/shm:/dev/shm" to "$rootfs/var/lib/dsh-app/shm:/dev/shm",
            "/system" to "/system:/system",
            "/apex" to "/apex:/apex",
        )
        val remaining = fixed.keys.toMutableSet()
        val guests = mutableSetOf<String>()
        // Not a PTY: tawcroot makes its own session (-s), like PRoot under ProcessBuilder.
        val argv = mutableListOf("$nativeLibraryDir/$LIBRARY", "-s", "-r", rootfs)
        var at = prefix.size
        while (at < envAt) {
            if (prootArgv[at] != "-b" || at + 1 >= envAt) throw Unsupported("bind")
            val value = prootArgv[at + 1]
            if (fixed.containsKey(value)) {
                if (!remaining.remove(value)) throw Unsupported("bind")
                fixed[value]?.let { argv += listOf("-b", it) }
            } else {
                val parts = value.split(':')
                if (parts.size !in 1..2 || parts.any { !absolutePath(it) }) throw Unsupported("bind")
                val host = parts[0]
                val guest = parts.getOrElse(1) { host }
                val alias = host == rootfs && guest == rootfs
                if (!alias && guest != "/sdcard" && guest != "/storage") throw Unsupported("bind")
                if (!guests.add(guest)) throw Unsupported("bind")
                argv += listOf("-b", "$host:$guest")
            }
            at += 2
        }
        if (remaining.isNotEmpty()) throw Unsupported("bind")
        argv += "--"
        // env -i, its assignments and the command are already prepared; pass them through untouched.
        argv += prootArgv.drop(envAt)
        val environment = hostEnvironment.filterKeys { !it.startsWith("PROOT_") && it != "LD_LIBRARY_PATH" }
        return Plan(argv, environment, "$rootfs/root", view)
    }

    /** (Re)creates the dev view's links; nothing else lives in that directory. */
    fun writeDevView(view: DevView) {
        val dir = File(view.directory)
        check(!Files.isSymbolicLink(dir.toPath()) && (dir.isDirectory || dir.mkdirs())) { "tawcroot: cannot create ${dir.name}" }
        for ((name, target) in view.links) {
            val link = File(dir, name).toPath()
            Files.deleteIfExists(link)
            Files.createSymbolicLink(link, File(target).toPath())
        }
    }

    private fun absolutePath(value: String): Boolean =
        value.startsWith('/') && value != "/" &&
            value.none { it == ':' || it == '\n' || it == '\u0000' } &&
            value.substring(1).split('/').all { it.isNotEmpty() && it != "." && it != ".." }
}
