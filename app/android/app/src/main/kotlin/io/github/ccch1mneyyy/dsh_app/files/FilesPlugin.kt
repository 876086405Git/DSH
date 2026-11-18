package io.github.ccch1mneyyy.dsh_app.files

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.ccch1mneyyy.dsh_app.runtime.PhoneStorage
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.security.MessageDigest
import kotlin.concurrent.thread

/**
 * Files the agent made for the user (chat deliverables / artifacts):
 * MethodChannel `dsh/files`.
 *
 * - `resolveGuest {path}` → host path of a local-engine file, or null.
 * - `listOutputs {depth}` → up to 500 most recently modified `[{path, bytes, modified}]` from
 *   `/sdcard/Download/DSH-Go` and the old `/sdcard/Download/DSH`
 *   (guest paths; empty without phone storage).
 * - `open {path, mime, name, chooser}` → ACTION_VIEW through this app's FileProvider.
 * - `saveToDownloads {path, name, mime}` → shown location (`Download/DSH-Go/x.pdf`):
 *   MediaStore Downloads on API 29+, the public Downloads directory before
 *   (asks for the storage permission when needed).
 *
 * - `pdfInfo {path}` → page sizes; `pdfPage {path, page, width}` → PNG bytes;
 *   `pdfClose` (in-app PDF preview, [PdfPages]).
 *
 * Errors: `missing` (no such readable file), `no_app` (nothing opens this
 * type), `permission` (storage write refused), `failed`.
 */
class FilesPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var methods: MethodChannel
    private lateinit var context: Context
    private var activity: ActivityPluginBinding? = null
    private var pendingSave: (() -> Unit)? = null
    private var pendingDenied: (() -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    private val pdfPages = PdfPages()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        methods.setMethodCallHandler(null)
        pdfPages.run({ close() }) {}
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        finishPermission(granted = false)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "resolveGuest" -> background(result) {
                GuestFiles.resolve(context, call.argument<String>("path") ?: "")?.absolutePath
            }
            "listOutputs" -> background(result) { listOutputs(call.argument<Int>("depth") ?: 3) }
            "open" -> open(call, result)
            "saveToDownloads" -> save(call, result)
            "pdfInfo" -> pdf(result) { info(call.argument<String>("path") ?: "") }
            "pdfPage" -> pdf(result) {
                render(call.argument<String>("path") ?: "", call.argument<Int>("page") ?: 0, call.argument<Int>("width") ?: 1080)
            }
            "pdfClose" -> pdf(result) { close() }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Open

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val file = File(call.argument<String>("path") ?: "")
        if (!file.isFile) return result.error("missing", "no such file", null)
        val name = call.argument<String>("name") ?: file.name
        val mime = mimeOf(call.argument<String>("mime"), name)
        val uri = try {
            contentUri(file, name)
        } catch (e: Exception) {
            return result.error("failed", e.message, null)
        }
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        view.clipData = ClipData.newRawUri(name, uri)
        if (view.resolveActivity(context.packageManager) == null) {
            return result.error("no_app", "no app opens $mime", null)
        }
        val launch = if (call.argument<Boolean>("chooser") == true) Intent.createChooser(view, null) else view
        val host: Activity? = activity?.activity
        try {
            if (host != null) {
                host.startActivity(launch)
            } else {
                context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            result.success(null)
        } catch (e: ActivityNotFoundException) {
            result.error("no_app", e.message, null)
        } catch (e: Exception) {
            result.error("failed", e.message, null)
        }
    }

    /**
     * A content URI for [file]: through the provider's roots when it lies in one,
     * else a copy in the cache's `artifacts/open` (named [name], so the
     * receiving app sees the real file name).
     */
    private fun contentUri(file: File, name: String): Uri {
        val authority = "${context.packageName}.files"
        return try {
            FileProvider.getUriForFile(context, authority, file)
        } catch (_: IllegalArgumentException) {
            val copy = copyForOpen(file, File(context.cacheDir, "artifacts/open"), name)
            FileProvider.getUriForFile(context, authority, copy)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Save to Downloads

    private fun save(call: MethodCall, result: MethodChannel.Result) {
        val file = File(call.argument<String>("path") ?: "")
        if (!file.isFile) return result.error("missing", "no such file", null)
        val name = safeName(call.argument<String>("name") ?: file.name)
        val mime = mimeOf(call.argument<String>("mime"), name)
        saveOrAsk(file, name, mime, result, asked = false)
    }

    /**
     * Saves on a worker thread. Android 8–9 need the storage permission for the
     * public Downloads directory, so it is asked for first; on 10+ it is asked
     * for only if MediaStore turns this (targetSdk 28) app away. Asked once per save.
     */
    private fun saveOrAsk(file: File, name: String, mime: String, result: MethodChannel.Result, asked: Boolean) {
        val retry = { saveOrAsk(file, name, mime, result, asked = true) }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && !canWriteShared()) {
            return if (asked) result.error("permission", "storage permission denied", null) else ask(result, retry)
        }
        thread(name = "dsh-files", isDaemon = true) {
            val outcome = runCatching { saveNow(file, name, mime) }
            main.post {
                val error = outcome.exceptionOrNull()
                val refused = error is SecurityException || (error is FilesError && error.code == "permission")
                when {
                    error == null -> result.success(outcome.getOrNull())
                    refused && !asked && activity != null -> ask(result, retry)
                    else -> fail(result, error)
                }
            }
        }
    }

    private fun ask(result: MethodChannel.Result, then: () -> Unit) {
        if (pendingSave != null) return result.error("permission", "storage permission request already pending", null)
        val host = activity?.activity ?: return result.error("permission", "no activity to ask for permission", null)
        val denied = { result.error("permission", "storage permission denied", null) }
        pendingSave = then
        pendingDenied = denied
        try {
            host.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), STORAGE_REQUEST)
        } catch (error: Exception) {
            // A synchronous callback may already have consumed this request.
            if (pendingDenied === denied) {
                pendingSave = null
                pendingDenied = null
                result.error("permission", error.message, null)
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != STORAGE_REQUEST) return false
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        finishPermission(granted)
        return true
    }

    private fun finishPermission(granted: Boolean) {
        val next = if (granted) pendingSave else pendingDenied
        pendingSave = null
        pendingDenied = null
        next?.invoke()
    }

    private fun saveNow(file: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                return saveToMediaStore(file, name, mime)
            } catch (e: SecurityException) {
                if (!canWriteShared()) throw FilesError("permission", e.message)
            } catch (e: IOException) {
                if (!canWriteShared()) throw e
            }
        }
        if (!canWriteShared()) throw FilesError("permission", "storage permission denied")
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val dir = File(downloads, SUBDIR).apply { mkdirs() }
        val target = file.inputStream().use { LegacyDownloads.copy(it, dir, name) }
        MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), arrayOf(mime), null)
        return "${Environment.DIRECTORY_DOWNLOADS}/$SUBDIR/${target.name}"
    }

    private fun saveToMediaStore(file: File, name: String, mime: String): String {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$SUBDIR")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: throw IOException("MediaStore refused the file")
        try {
            resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
                ?: throw IOException("cannot write $uri")
            if (resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null) <= 0) {
                throw IOException("cannot publish file")
            }
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        // MediaStore renames on collision ("report (1).pdf"): report the name it kept.
        val shown = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: name
        return "${Environment.DIRECTORY_DOWNLOADS}/$SUBDIR/$shown"
    }

    private fun canWriteShared(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) return true
        val granted = context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        if (!granted) return false
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || Environment.isExternalStorageLegacy()
    }

    // ---------------------------------------------------------------------------------------------
    // The phone's output folder

    private fun listOutputs(depth: Int): List<Map<String, Any>> {
        if (!PhoneStorage.isGranted(context)) return emptyList()
        val hostRoot = PhoneStorage.hostRoot()
        val out = ArrayList<Map<String, Any>>()
        fun walk(dir: File, level: Int) {
            val children = dir.listFiles() ?: return
            for (child in children.sortedBy { it.name }) {
                if (child.name.startsWith(".")) continue
                if (child.isDirectory) {
                    if (level < depth) walk(child, level + 1)
                } else if (child.isFile) {
                    out += mapOf(
                        "path" to PhoneStorage.GUEST_PATH + child.absolutePath.removePrefix(hostRoot),
                        "bytes" to child.length(),
                        "modified" to child.lastModified(),
                    )
                }
            }
        }
        // The old folder too: earlier chats' files, and a user's own AGENTS.md that still names it.
        for (folder in listOf(SUBDIR, LEGACY_SUBDIR)) walk(File(hostRoot, "${Environment.DIRECTORY_DOWNLOADS}/$folder"), 1)
        return out.sortedByDescending { it["modified"] as Long }.take(MAX_OUTPUTS)
    }

    // ---------------------------------------------------------------------------------------------

    private fun <T> background(result: MethodChannel.Result, work: () -> T) {
        thread(name = "dsh-files", isDaemon = true) {
            val outcome = try {
                Result.success(work())
            } catch (e: Throwable) {
                Result.failure(e)
            }
            main.post { outcome.fold(onSuccess = { result.success(it) }, onFailure = { fail(result, it) }) }
        }
    }

    private fun <T> pdf(result: MethodChannel.Result, work: PdfPages.() -> T) {
        pdfPages.run(work) { outcome ->
            main.post {
                outcome.fold(
                    onSuccess = { result.success(if (it is Unit) null else it) },
                    onFailure = { e -> if (e is java.io.FileNotFoundException) result.error("missing", e.message, null) else fail(result, e) },
                )
            }
        }
    }

    private fun fail(result: MethodChannel.Result, e: Throwable) = when (e) {
        is FilesError -> result.error(e.code, e.message, null)
        is SecurityException -> result.error("permission", e.message, null)
        else -> result.error("failed", e.message ?: e.javaClass.simpleName, null)
    }

    private class FilesError(val code: String, message: String?) : Exception(message)

    companion object {
        const val CHANNEL = "dsh/files"
        /** `Download/DSH-Go`: saved files, and the local engine's output folder (GuestSetup). No
         *  space: the agent types this path into shell commands. */
        private const val SUBDIR = "DSH-Go"
        /** The folder before the app was called DSH Go; nothing is written there any more. */
        private const val LEGACY_SUBDIR = "DSH"
        private const val STORAGE_REQUEST = 0x5d6
        private const val MAX_OUTPUTS = 500

        /** [given] unless it is missing or generic, else the platform's guess from [name]'s extension. */
        fun mimeOf(given: String?, name: String): String {
            if (!given.isNullOrBlank() && given != "application/octet-stream") return given
            val ext = name.substringAfterLast('.', "").lowercase()
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }

        /** A file name without path separators or control characters. */
        fun safeName(name: String): String {
            val cleaned = name.substringAfterLast('/').replace(Regex("[\\u0000-\\u001f\\\\:*?\"<>|]"), "_").trim()
            return cleaned.ifEmpty { "file" }
        }

        /** Stable per-source copies: another source cannot replace an already shared URI. */
        internal fun copyForOpen(
            file: File,
            root: File,
            name: String,
            copy: (File, File) -> Unit = { from, to -> from.copyTo(to, overwrite = true) },
        ): File {
            val source = file.canonicalFile
            val key = MessageDigest.getInstance("SHA-256")
                .digest(source.path.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
            val target = File(File(root, key), safeName(name))
            val directory = target.parentFile!!
            directory.mkdirs()
            val temporary = File.createTempFile(".open-", ".part", directory)
            try {
                copy(source, temporary)
                // An older URI stays readable until its complete replacement is ready.
                Files.move(temporary.toPath(), target.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
                return target
            } finally {
                temporary.delete()
            }
        }

        /** [name] in [dir], or `name (2).ext`, `name (3).ext`… when taken. */
        fun unique(dir: File, name: String): File {
            var candidate = File(dir, name)
            if (!candidate.exists()) return candidate
            val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
            val stem = name.substring(0, dot)
            val ext = name.substring(dot)
            var n = 2
            while (candidate.exists()) candidate = File(dir, "$stem ($n)$ext").also { n++ }
            return candidate
        }
    }
}
