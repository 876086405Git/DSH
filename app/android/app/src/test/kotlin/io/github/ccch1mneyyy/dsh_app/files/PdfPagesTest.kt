package io.github.ccch1mneyyy.dsh_app.files

import org.junit.Assert.assertEquals
import org.junit.Test

class PdfPagesTest {
    @Test
    fun tallPageKeepsItsAspectRatioAtTheHeightLimit() {
        // A 200 x 1200 point receipt, displayed at 400 dp with a device pixel ratio of 3.
        assertEquals(800 to 4800, pdfPageBitmapSize(200, 1200, 1200))
    }
}
