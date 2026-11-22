package io.github.ccch1mneyyy.dsh_app.nativefiles

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.ccch1mneyyy.dsh_app.MainActivity
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.Executors

/** System selection only. No storage permission, write mode, persistent URI grant or cache copy. */
class NativeFilesPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private data class FileEntry(val handle: String, val uri: Uri, val name: String, val size: Long?, val mime: String) {
        @Volatile var stream: InputStream? = null
        var ended = false
    }
    private class Selection(val owner: String, val budget: SelectedFileBudget) {
        val signal = CancellationSignal()
        val files = mutableListOf<FileEntry>()
        @Volatile var active = true
    }
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private var binding: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    // At most one read/query job and one close job; no unbounded work queue.
    private val worker = Executors.newFixedThreadPool(2)
    private var ioBusy = false
    private var closing = false
    private var waitingForPicker = false
    private var pending: MethodChannel.Result? = null
    private var selection: Selection? = null
    private val expire = Runnable { cancelSelection() }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "dsh/native-files").also { it.setMethodCallHandler(this) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        cancelSelection()
        worker.shutdown()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeActivityResultListener(this)
        binding = null
        // Existing result may still reach the reattached engine. Revoke its owner now.
        cancelSelection()
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        waitingForPicker = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(mapOf("files" to true))
            "pick" -> pick(call, result)
            "cancel" -> {
                if (call.argument<String>("owner") == selection?.owner) cancelSelection()
                result.success(null)
            }
            "read" -> read(call, result)
            else -> result.notImplemented()
        }
    }

    /** [visual]: photos and videos (a custom launch screen); [images]: photos only. */
    private fun documentIntent(images: Boolean, multiple: Boolean, visual: Boolean = false) =
        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (images && !visual) "image/*" else "*/*"
            if (visual) putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

    private fun pick(call: MethodCall, result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null || !MainActivity.inForeground || call.argument<Boolean>("userGesture") != true) {
            result.error("unavailable", "selection needs a foreground tap", null); return
        }
        if (waitingForPicker || pending != null || selection != null || ioBusy || closing) {
            result.error("busy", "a file selection is already active", null); return
        }
        val owner = call.argument<String>("owner") ?: ""
        if (!owner.matches(Regex("^[A-Za-z0-9_-]{32}$"))) { result.error("invalid", "invalid owner", null); return }
        val budget = try {
            SelectedFileBudget(call.argument<Int>("maxFiles") ?: 1, call.argument<Int>("maxBytes") ?: 0,
                call.argument<Int>("maxTotalBytes") ?: 0, own = call.argument<Boolean>("own") == true)
        } catch (_: IllegalArgumentException) { result.error("invalid", "invalid byte budget", null); return }
        val images = call.argument<Boolean>("images") == true
        val visual = call.argument<Boolean>("visual") == true
        val intent = if ((images || visual) && Build.VERSION.SDK_INT >= 33) Intent(MediaStore.ACTION_PICK_IMAGES).apply {
            // No type: the photo picker offers photos and videos.
            if (!visual) type = "image/*"
            val count = minOf(budget.maxFiles, MediaStore.getPickImagesMaxLimit())
            if (count > 1) putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, count)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } else documentIntent(images, budget.maxFiles > 1, visual)
        selection = Selection(owner, budget)
        pending = result
        waitingForPicker = true
        main.postDelayed(expire, 5 * 60 * 1000L)
        try {
            try { activity.startActivityForResult(intent, REQUEST) }
            catch (_: ActivityNotFoundException) { activity.startActivityForResult(documentIntent(images, budget.maxFiles > 1, visual), REQUEST) }
        } catch (_: Exception) {
            waitingForPicker = false
            pending = null
            cancelSelection()
            result.error("unavailable", "no system file selector", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        waitingForPicker = false
        val s = selection ?: return true
        val result = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            cancelSelection(); result.success(null); return true
        }
        // Reject the count before collecting URIs or opening any content provider.
        val count = data.clipData?.itemCount ?: if (data.data != null) 1 else 0
        if (count !in 1..s.budget.maxFiles) {
            cancelSelection(); result.error("too-large", "too many selected files", null); return true
        }
        val uris = (0 until count).map { data.clipData?.getItemAt(it)?.uri ?: data.data!! }
        io(result, s) {
            val entries = uris.map { uri ->
                require(uri.scheme == "content") { "unsupported URI" }
                var name = "file"
                var size: Long? = null
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null, null, null, s.signal)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val ni = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0 && !cursor.isNull(ni)) name = cursor.getString(ni)
                        if (si >= 0 && !cursor.isNull(si)) size = cursor.getLong(si).takeIf { it >= 0 }
                    }
                }
                val cleaned = name.substringAfterLast('/').substringAfterLast('\\').filter { it >= ' ' && it != '\u007f' }
                val cut = if (cleaned.length > 128 && cleaned[127].isHighSurrogate() && cleaned[128].isLowSurrogate()) 127 else 128
                val safeName = cleaned.take(cut).takeIf { label ->
                    label.any { !it.isWhitespace() && it !in '\u007f'..'\u009f' && it != '\uFEFF' }
                } ?: "file"
                val mime = context.contentResolver.getType(uri)?.takeIf {
                    it.matches(Regex("^[A-Za-z0-9][A-Za-z0-9!#\$&^_.+-]{0,63}/[A-Za-z0-9][A-Za-z0-9!#\$&^_.+-]{0,63}$"))
                } ?: "application/octet-stream"
                FileEntry(UUID.randomUUID().toString(), uri, safeName, size, mime)
            }
            s.budget.metadata(entries.map { it.size })
            synchronized(s.files) { s.files.addAll(entries) }
            entries.map { mapOf("handle" to it.handle, "name" to it.name, "bytes" to it.size, "mediaType" to it.mime) }
        }
        return true
    }

    private fun read(call: MethodCall, result: MethodChannel.Result) {
        val s = selection
        val handle = call.argument<String>("handle")
        val entry = if (s == null) null else synchronized(s.files) { s.files.find { it.handle == handle } }
        if (s == null || !s.active || call.argument<String>("owner") != s.owner || entry == null) {
            result.error("cancelled", "file selection expired", null); return
        }
        io(result, s) {
            if (entry.ended) return@io null
            val input = entry.stream ?: run {
                val descriptor = context.contentResolver.openAssetFileDescriptor(entry.uri, "r", s.signal)
                    ?: error("cannot read selected file")
                try { descriptor.createInputStream().also { entry.stream = it } }
                catch (error: Exception) { descriptor.close(); throw error }
            }
            if (!s.active) { input.close(); error("cancelled") }
            val buffer = ByteArray(s.budget.chunkSize(entry.handle))
            val count = input.read(buffer)
            check(count != 0) { "empty file chunk" }
            if (count < 0) { input.close(); entry.stream = null; entry.ended = true; null }
            else { s.budget.accept(entry.handle, count); if (count == buffer.size) buffer else buffer.copyOf(count) }
        }
    }

    private fun io(result: MethodChannel.Result, s: Selection, work: () -> Any?) {
        if (ioBusy || closing) { result.error("busy", "file reader is busy", null); return }
        ioBusy = true
        worker.execute {
            var value: Any? = null
            var error: Exception? = null
            try { value = work() } catch (e: Exception) { error = e }
            main.post {
                ioBusy = false
                if (selection !== s || !s.active) result.error("cancelled", "file selection expired", null)
                else if (error != null) {
                    cancelSelection()
                    result.error(if (error.message == "too-large") "too-large" else "failed", "cannot read selected file", null)
                } else result.success(value)
            }
        }
    }

    private fun cancelSelection() {
        main.removeCallbacks(expire)
        pending?.success(null)
        pending = null
        val s = selection ?: return
        selection = null
        s.active = false
        s.signal.cancel()
        closing = true
        worker.execute {
            synchronized(s.files) { s.files.forEach { runCatching { it.stream?.close() }; it.stream = null }; s.files.clear() }
            main.post { closing = false }
        }
    }

    companion object { private const val REQUEST = 0x6D53 }
}
