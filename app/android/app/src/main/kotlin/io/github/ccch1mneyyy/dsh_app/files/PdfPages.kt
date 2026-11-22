package io.github.ccch1mneyyy.dsh_app.files

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/** Fit the requested raster within both limits without stretching a tall page. */
internal fun pdfPageBitmapSize(pageWidth: Int, pageHeight: Int, requestedWidth: Int): Pair<Int, Int> {
    val width = requestedWidth.coerceIn(64, 2400)
    val height = width.toLong() * pageHeight / pageWidth.coerceAtLeast(1)
    if (height <= 4800) return width to height.toInt().coerceAtLeast(1)
    return (4800L * pageWidth / pageHeight).toInt().coerceAtLeast(1) to 4800
}

/**
 * In-app PDF preview pages (the official Web client previews PDFs in its
 * sidebar). One document stays open at a time; [PdfRenderer] is not
 * thread-safe, so every call runs on one worker thread.
 */
class PdfPages {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "dsh-pdf").apply { isDaemon = true } }
    private var path: String? = null
    private var fd: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null

    fun <T> run(work: PdfPages.() -> T, done: (Result<T>) -> Unit) {
        worker.execute { done(runCatching { work() }) }
    }

    /** Page sizes in PDF points: `[{width, height}, …]`. */
    fun info(path: String): List<Map<String, Int>> {
        val doc = open(path)
        return (0 until doc.pageCount).map { i ->
            doc.openPage(i).use { mapOf("width" to it.width, "height" to it.height) }
        }
    }

    /** Page [index] as PNG, fitting the requested [width] and raster limits, on white. */
    fun render(path: String, index: Int, width: Int): ByteArray {
        val doc = open(path)
        doc.openPage(index).use { page ->
            val (w, h) = pdfPageBitmapSize(page.width, page.height, width)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                return ByteArrayOutputStream().use { out ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                    out.toByteArray()
                }
            } finally {
                bitmap.recycle()
            }
        }
    }

    fun close() {
        renderer?.close()
        fd?.close()
        renderer = null
        fd = null
        path = null
    }

    private fun open(path: String): PdfRenderer {
        renderer?.let { if (this.path == path) return it }
        close()
        val descriptor = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            val doc = PdfRenderer(descriptor)
            fd = descriptor
            renderer = doc
            this.path = path
            return doc
        } catch (e: Exception) {
            descriptor.close()
            throw e
        }
    }
}
