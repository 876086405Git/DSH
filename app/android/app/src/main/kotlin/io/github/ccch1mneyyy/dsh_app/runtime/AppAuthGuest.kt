package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption

/**
 * Subscription sign-in (ChatGPT, Claude) for the local engine. DSH 0.2.1 carries both flows in its
 * built-in `llm-pi-ai` adapter but gives clients no way to start one; the app's auth bridge plugin
 * (`app/assets/engine/auth/`, Remote service `appAuth`) does, and declares the provider's route
 * once a sign-in succeeds.
 *
 * Written at every engine start like message search (no rootfs rebuild): the bridge modules go to
 * [GUEST_DIR] straight from the Flutter asset bundle, then the overlay that inserts the plugin by
 * absolute path. The overlay is passed with --patch on normal launches only, never in safe mode,
 * and only when everything was written. A plugin that fails to load leaves DSH running (it reports
 * "entries did not activate"); only the `appAuth` methods are missing then.
 */
object AppAuthGuest {
    const val GUEST_DIR = "/opt/dsh-app/auth"
    const val PATCH = "$GUEST_DIR/auth.patch.yml"
    const val ENTRY = "$GUEST_DIR/index.mjs"

    /** Where Flutter packs `app/assets/engine/auth/` inside the APK's assets. */
    private const val ASSET_DIR = "flutter_assets/assets/engine/auth"
    private val MODULES = listOf("index.mjs", "bridge.mjs")

    private const val WEB_PATCH_ARG = "--patch /etc/dsh-app/dsh-web.patch.yml"
    private const val DSH_WEB = "/usr/local/bin/dsh web"

    val PATCH_YAML = """# dsh-app: subscription sign-in (ChatGPT, Claude). The DSH App rewrites this directory at every
# engine start and passes this file with --patch on normal launches (never in safe mode). Edits do
# not survive.
- insert:
    - id: dsh-app-auth
      name: $ENTRY
"""

    /** The launch shell command with the overlay right after the app's own one; null when [arg] is not the `dsh web` launch. */
    fun launchArg(arg: String): String? {
        val web = arg.indexOf("$DSH_WEB ")
        if (web < 0 || arg.indexOf("$DSH_WEB ", web + 1) >= 0 || arg.contains("--profile")) return null
        val patch = arg.indexOf(WEB_PATCH_ARG, web)
        val at = if (patch >= 0 && arg.indexOf(WEB_PATCH_ARG, patch + 1) < 0) patch + WEB_PATCH_ARG.length else web + DSH_WEB.length
        return arg.substring(0, at) + " --patch $PATCH" + arg.substring(at)
    }

    fun file(rootfs: File) = File(rootfs, PATCH.removePrefix("/"))

    /**
     * Copies the bridge modules, then writes the overlay; files already up to date are left alone.
     * False when anything could not be written, so this launch leaves it out; cleanup is best effort.
     */
    fun writeFiles(context: Context, rootfs: File): Boolean {
        val patch = file(rootfs)
        return try {
            val dir = File(rootfs, GUEST_DIR.removePrefix("/"))
            if (Files.isSymbolicLink(dir.toPath()) || (dir.exists() && !dir.isDirectory)) dir.delete()
            if (!dir.isDirectory && !dir.mkdirs()) throw IOException("could not create ${dir.path}")
            for (name in MODULES) {
                val bytes = context.assets.open("$ASSET_DIR/$name").use { it.readBytes() }
                writeIfChanged(File(dir, name), bytes)
            }
            writeIfChanged(patch, PATCH_YAML.toByteArray())
            true
        } catch (_: Exception) {
            patch.delete()
            false
        }
    }

    /** SIWC is optional: a failed copy must not remove the existing auth overlay. */
    fun writeSiwcFiles(context: Context, rootfs: File): Boolean = try {
        val modules = context.assets.list("$ASSET_DIR/siwc").orEmpty().filter { it.endsWith(".mjs") }
        if (!modules.containsAll(listOf("store.mjs", "oauth.mjs", "provider.mjs"))) {
            throw IOException("SIWC assets are incomplete")
        }
        val dir = File(rootfs, "${GUEST_DIR.removePrefix("/")}/siwc")
        if (!Files.isDirectory(dir.toPath(), LinkOption.NOFOLLOW_LINKS) && !dir.mkdir()) {
            throw IOException("could not create SIWC asset directory")
        }
        for (name in modules) {
            val bytes = context.assets.open("$ASSET_DIR/siwc/$name").use { it.readBytes() }
            writeIfChanged(File(dir, name), bytes)
        }
        true
    } catch (_: Exception) {
        false
    }

    /** Sibling temp file renamed over [target]; only a regular file is compared (never a link or FIFO). */
    private fun writeIfChanged(target: File, bytes: ByteArray) {
        if (Files.isRegularFile(target.toPath(), LinkOption.NOFOLLOW_LINKS) && target.readBytes().contentEquals(bytes)) return
        val tmp = File(target.parentFile, ".${target.name}.dsh-app-${System.nanoTime()}.tmp")
        try {
            tmp.writeBytes(bytes)
            tmp.setReadable(true, false)
            if (!tmp.renameTo(target)) throw IOException("could not replace ${target.path}")
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }
}
