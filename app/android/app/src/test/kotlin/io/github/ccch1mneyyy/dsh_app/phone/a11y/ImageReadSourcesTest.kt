package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.view.accessibility.AccessibilityWindowInfo
import io.github.ccch1mneyyy.dsh_app.phone.PhonePolicies
import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks
import io.github.ccch1mneyyy.dsh_app.phone.SafetyGate
import io.github.ccch1mneyyy.dsh_app.phone.ScreenSnapshot
import org.junit.Assert.*
import org.junit.Test

class ImageReadSourcesTest {
    private val own = "example.own"
    private val app = AccessibilityWindowInfo.TYPE_APPLICATION
    private val overlay = AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY
    private val box = Box(0, 0, 100, 200)
    private fun cap(metadata: List<CapturedImageWindow>, windows: List<UiWindow> = emptyList()) = Capture(
        windows, emptyList(), false, box, "example.a", false, false, false,
        takenAt = 0L, imageWindows = metadata,
    )
    private fun shot(windowId: Int? = null, hidden: Set<Int> = emptySet(), bytes: ByteArray? = byteArrayOf(1)) =
        Shot(bytes, if (bytes == null) null else "image/jpeg", null, false, null,
            capturedWindowId = windowId, hiddenOverlayWindowIds = hidden)
    private fun window(id: Int, pkg: String?) = UiWindow(id, WindowKind.APP, pkg, null, box, null)

    @Test fun actualWindowTargetIncludesOnlyThatIdAndKeepsBothKnownPackages() {
        val source = cap(listOf(CapturedImageWindow(1, app, "example.a"),
            CapturedImageWindow(2, app, "example.denied")), listOf(window(1, "example.a2"), window(2, "example.denied")))
        assertEquals(setOf("example.a", "example.a2"), ImageReadSources.knownPackages(source, shot(1), own))
    }

    @Test fun displayKeepsAllKnownMetadataEvenOutsideTheContentSubset() {
        val metadata = (1..5).map { CapturedImageWindow(it, app, "example.a$it") } + listOf(
            CapturedImageWindow(6, AccessibilityWindowInfo.TYPE_INPUT_METHOD, "example.ime"),
            CapturedImageWindow(7, AccessibilityWindowInfo.TYPE_SYSTEM, "example.system"),
            CapturedImageWindow(8, overlay, own), CapturedImageWindow(9, overlay, "example.other"))
        assertEquals((1..5).map { "example.a$it" }.toSet() + setOf("example.ime", "example.system", own, "example.other"),
            ImageReadSources.knownPackages(cap(metadata, listOf(window(1, "example.a1"))), shot(), own))
    }

    @Test fun onlyThisDisplayHiddenOwnOverlayIdCanBeOmitted() {
        val hidden = CapturedImageWindow(7, overlay, own)
        assertEquals(emptySet<String>(), ImageReadSources.knownPackages(cap(listOf(hidden)), shot(hidden = setOf(7)), own))
        assertEquals(setOf(own), ImageReadSources.knownPackages(cap(listOf(hidden)), shot(hidden = setOf(8)), own))
        assertEquals(setOf(own), ImageReadSources.knownPackages(cap(listOf(hidden.copy(type = app))), shot(hidden = setOf(7)), own))
        assertEquals(setOf("example.other"), ImageReadSources.knownPackages(cap(listOf(hidden.copy(packageName = "example.other"))), shot(hidden = setOf(7)), own))
        assertEquals(setOf(own), ImageReadSources.knownPackages(cap(listOf(hidden)), shot(windowId = 7, hidden = setOf(7)), own))
        assertEquals(setOf(own), ImageReadSources.knownPackages(cap(listOf(hidden, hidden.copy(id = 8))), shot(hidden = setOf(7)), own))
    }

    @Test fun sameCaptureContentKnowledgeSurvivesUnknownMetadata() {
        val source = cap(listOf(CapturedImageWindow(1, app, null)), listOf(window(1, "example.a")))
        assertEquals(setOf("example.a"), ImageReadSources.knownPackages(source, shot(), own))
        assertEquals(setOf("example.a"), ImageReadSources.knownPackages(source, shot(1), own))
    }

    @Test fun missingImageAndUnknownMetadataDoNotInventSources() {
        val source = cap(listOf(CapturedImageWindow(1, app, null), CapturedImageWindow(2, app, " ")))
        assertEquals(emptySet<String>(), ImageReadSources.knownPackages(source, shot(), own))
        assertEquals(emptySet<String>(), ImageReadSources.knownPackages(cap(listOf(CapturedImageWindow(1, app, "example.a"))), shot(bytes = null), own))
    }

    @Test fun actualMappingFeedsTheOriginalSafetyGateWithoutChangingTextSources() {
        val capture = cap(listOf(CapturedImageWindow(1, app, "example.a"), CapturedImageWindow(2, app, "example.b")))
        val gate = SafetyGate({ PhonePolicies(denyPackages = listOf("example.b")) }, PhoneTasks(), { null })
        fun result(shot: Shot) = ScreenSnapshot("s1", "合法正文", "A", "example.a", image = shot.bytes,
            imageMime = shot.mime, readPackages = setOf("example.a"),
            imageReadPackages = ImageReadSources.knownPackages(capture, shot, own))
        val display = result(shot())
        val filtered = gate.filterScreen(display)
        assertTrue(filtered.text.startsWith("合法正文"))
        assertEquals(setOf("example.a"), filtered.readPackages)
        assertNull(filtered.image)
        val window = result(shot(1))
        assertSame(window, gate.filterScreen(window))

        val goodRoot = UiNode(bounds = box, children = listOf(
            UiNode(bounds = Box(0, 0, 100, 20), text = "Overview"),
            UiNode(bounds = Box(0, 30, 100, 50), text = "Summary"),
            UiNode(bounds = Box(0, 60, 100, 80), text = "Help"),
            UiNode(bounds = Box(0, 90, 100, 110), text = "Next"),
            UiNode(bounds = Box(0, 120, 100, 140), text = "Done"),
        ))
        val allowed = cap(listOf(CapturedImageWindow(1, app, "example.a")),
            listOf(UiWindow(1, WindowKind.APP, "example.a", null, box, goodRoot)))
        val formatted = ScreenFormat.format(ScreenInput("image", "A", "example.a", 100, 200,
            false, allowed.windows))
        val card = "4111 1111 1111 1111"
        assertTrue(formatted.textNodes >= ScreenFormat.POOR_TREE)
        assertFalse(formatted.poorTree)
        assertFalse(formatted.text.contains(card))
        assertFalse(formatted.text.contains("«银行卡"))
        assertTrue(ScreenMask.mask(card).startsWith("«银行卡"))

        // Controlled recognition at the actual borrowed-frame boundary; no bitmap/engine claim.
        fun recognized(texts: List<String>) = LocalOcrBoundary.read(true, true, 100, 200, 10L,
            { 1L }, { false }, {
                LocalOcrResult.Recognized(texts.mapIndexed { index, text ->
                    LocalOcrResult.Line(text, 1, index * 20 + 1, 99, index * 20 + 10)
                })
            })
        val pixels = byteArrayOf(1)
        fun exported(localText: LocalOcrResult, capturedEpoch: Long? = 7L,
                     currentEpoch: Long? = 7L): ScreenSnapshot {
            val bytes = companionScreenImage(pixels, "example.a", localText, capturedEpoch, currentEpoch)
            val candidate = shot(1, bytes = bytes)
            return gate.filterScreen(ScreenSnapshot("image", formatted.text, "A", "example.a",
                image = candidate.bytes, imageMime = candidate.mime, readPackages = setOf("example.a"),
                imageReadPackages = ImageReadSources.knownPackages(allowed, candidate, own)))
        }
        val cardOnly = recognized(listOf(card))
        assertTrue(cardOnly is LocalOcrResult.Recognized)
        val withoutCardImage = exported(cardOnly)
        assertNull(withoutCardImage.image)
        assertEquals(formatted.text, withoutCardImage.text)
        assertEquals(setOf("example.a"), withoutCardImage.readPackages)

        val lateCard = recognized(listOf("plain ".repeat(501), card))
        assertTrue(lateCard is LocalOcrResult.Recognized)
        assertNull(exported(lateCard).image)
        val clean = recognized(listOf("Ordinary local text"))
        assertTrue(clean is LocalOcrResult.Recognized)
        val withCleanImage = exported(clean)
        assertSame(pixels, withCleanImage.image)
        assertEquals(formatted.text, withCleanImage.text)
        assertEquals(setOf("example.a"), withCleanImage.imageReadPackages)
        assertNull(exported(clean, currentEpoch = 8L).image)
        assertNull(exported(clean, currentEpoch = null).image)
        assertNull(exported(clean, capturedEpoch = null, currentEpoch = null).image)
        assertNull(exported(recognized(emptyList())).image)
        assertNull(exported(recognized(listOf("   "))).image)
        assertNull(exported(LocalOcrResult.Unavailable(LocalOcrResult.Reason.DISABLED)).image)
        assertNull(exported(LocalOcrResult.Failed(LocalOcrResult.Failure.ENGINE)).image)


        // Wrapped OCR stays at the same real boundary; all original checks above remain.
        val splitCard = recognized(listOf("4111 1111", "1111 1111"))
        assertTrue(splitCard is LocalOcrResult.Recognized)
        val withoutSplitImage = exported(splitCard)
        assertNull(withoutSplitImage.image)
        assertNull(withoutSplitImage.imageMime)
        assertEquals(formatted.text, withoutSplitImage.text)
        assertEquals(setOf("example.a"), withoutSplitImage.readPackages)

        val fourLineCard = recognized(listOf("4111", "1111", "1111", "1111"))
        assertTrue(fourLineCard is LocalOcrResult.Recognized)
        assertNull(exported(fourLineCard).image)
        val paddedCard = recognized(listOf(" \t4111 1111 ", "", " \t", " 1111 1111\t "))
        assertTrue(paddedCard is LocalOcrResult.Recognized)
        assertNull(exported(paddedCard).image)
        val trailingHyphenCard = recognized(listOf("4111 1111-", "1111 1111"))
        assertTrue(trailingHyphenCard is LocalOcrResult.Recognized)
        assertNull(exported(trailingHyphenCard).image)
        val leadingHyphenCard = recognized(listOf("4111 1111", "-1111 1111"))
        assertTrue(leadingHyphenCard is LocalOcrResult.Recognized)
        assertNull(exported(leadingHyphenCard).image)
        val lateSplitCard = recognized(listOf("plain ".repeat(501), "4111 1111", "1111 1111"))
        assertTrue(lateSplitCard is LocalOcrResult.Recognized)
        assertNull(exported(lateSplitCard).image)

        // A joined order label must not undo the original per-line card rejection.
        val orderThenCard = recognized(listOf("订单", card))
        assertTrue(orderThenCard is LocalOcrResult.Recognized)
        assertNull(exported(orderThenCard).image)
        val multiLineClean = recognized(listOf("Overview", "Monthly summary", "Next"))
        assertTrue(multiLineClean is LocalOcrResult.Recognized)
        val withMultiLineImage = exported(multiLineClean)
        assertSame(pixels, withMultiLineImage.image)
        assertEquals(formatted.text, withMultiLineImage.text)
        assertEquals(setOf("example.a"), withMultiLineImage.readPackages)
        assertEquals(setOf("example.a"), withMultiLineImage.imageReadPackages)
        val separateNumbers = recognized(listOf("Items 8", "Date 2026-11-24", "Reference 12345678"))
        assertTrue(separateNumbers is LocalOcrResult.Recognized)
        val withSeparateNumbersImage = exported(separateNumbers)
        assertSame(pixels, withSeparateNumbersImage.image)
        assertEquals(formatted.text, withSeparateNumbersImage.text)
        assertEquals(setOf("example.a"), withSeparateNumbersImage.readPackages)
        assertEquals(setOf("example.a"), withSeparateNumbersImage.imageReadPackages)
    }
}
