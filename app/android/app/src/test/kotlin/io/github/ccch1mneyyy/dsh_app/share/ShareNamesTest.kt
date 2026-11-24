package io.github.ccch1mneyyy.dsh_app.share

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class ShareNamesTest {
    @Test fun safeNameDropsPathsControlsAndLeadingDots() {
        assertEquals("passwd", ShareNames.safeName("../../etc/passwd"))
        assertEquals("a_b_c.txt", ShareNames.safeName("a:b*c.txt"))
        assertEquals("bashrc", ShareNames.safeName(".bashrc"))
        assertEquals("shared", ShareNames.safeName("  "))
        assertEquals(120, ShareNames.safeName("x".repeat(300)).length)
    }

    @Test fun addsAnExtensionOnlyWhenMissing() {
        assertEquals("图片.jpg", ShareNames.withExtension("图片", "jpg"))
        assertEquals("报告.pdf", ShareNames.withExtension("报告.pdf", "png"))
        assertEquals("note.", ShareNames.withExtension("note.", null))
        assertEquals("note..txt", ShareNames.withExtension("note.", "txt"))
        assertEquals("profile.dshgo", ShareNames.withExtension("profile", ShareNames.SHARE_CODE_EXTENSION))
    }

    @Test fun fallbackNamesFollowTheType() {
        assertEquals("图片", ShareNames.fallbackName("image/heic"))
        assertEquals("视频", ShareNames.fallbackName("video/mp4"))
        assertEquals("文本", ShareNames.fallbackName("text/plain"))
        assertEquals("文件", ShareNames.fallbackName(null))
    }

    @Test fun replacesTheExtension() {
        assertEquals("IMG_1.jpg", ShareNames.replaceExtension("IMG_1.HEIC", "jpg"))
        assertEquals("photo.png", ShareNames.replaceExtension("photo", "png"))
    }

    @Test fun uniqueNamesCountUp() {
        val dir = Files.createTempDirectory("share").toFile()
        try {
            assertEquals("a.jpg", ShareNames.unique(dir, "a.jpg").name)
            File(dir, "a.jpg").writeText("1")
            assertEquals("a (2).jpg", ShareNames.unique(dir, "a.jpg").name)
            File(dir, "a (2).jpg").writeText("2")
            assertEquals("a (3).jpg", ShareNames.unique(dir, "a.jpg").name)
            File(dir, "README").writeText("3")
            assertEquals("README (2)", ShareNames.unique(dir, "README").name)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun safeNameDoesNotSplitAnEmojiAtItsUtf16Limit() {
        assertEquals("a".repeat(119), ShareNames.safeName("a".repeat(119) + "😀"))
        assertEquals("a".repeat(118) + "😀", ShareNames.safeName("a".repeat(118) + "😀"))
    }

    @Test fun finalNamesBudgetAddedExtensionsAndEveryCollision() {
        val dir = Files.createTempDirectory("share-names").toFile()
        try {
            val shown = ShareNames.withExtension(ShareNames.safeName("界".repeat(120)), "dshgo")
            val created = mutableSetOf<String>()
            for (n in 1..10) {
                val file = ShareNames.unique(dir, shown)
                assertTrue(file.name.toByteArray(Charsets.UTF_8).size <= 255)
                assertTrue(file.name.endsWith(".dshgo"))
                if (n > 1) assertTrue(file.name.endsWith(" ($n).dshgo"))
                assertTrue(created.add(file.name))
                file.writeBytes(byteArrayOf(n.toByte()))
                assertArrayEquals(byteArrayOf(n.toByte()), file.readBytes())
            }
            assertEquals(10, dir.listFiles()!!.size)
            val atLimit = ShareNames.withExtension("界".repeat(85), "jpg")
            val image = ShareNames.unique(dir, atLimit)
            assertTrue(image.name.toByteArray(Charsets.UTF_8).size <= 255)
            assertTrue(image.name.endsWith(".jpg"))
            image.writeBytes(byteArrayOf(42))
        } finally { dir.deleteRecursively() }
    }

    @Test fun replacingAnExtensionIsBudgetedAgainAtTheActualOutput() {
        val dir = Files.createTempDirectory("share-image-name").toFile()
        try {
            val original = ShareNames.unique(dir, "界".repeat(84) + "a.x")
            assertEquals(255, original.name.toByteArray(Charsets.UTF_8).size)
            original.writeBytes(byteArrayOf(1))
            val converted = ShareNames.unique(dir, ShareNames.replaceExtension(original.name, "jpg"))
            assertTrue(converted.name.endsWith(".jpg"))
            assertTrue(converted.name.toByteArray(Charsets.UTF_8).size <= 255)
            converted.writeBytes(byteArrayOf(2))
            assertArrayEquals(byteArrayOf(1), original.readBytes())
            assertArrayEquals(byteArrayOf(2), converted.readBytes())
        } finally { dir.deleteRecursively() }
    }

    @Test fun oversizedExtensionFallsBackWithoutSplittingCodePoints() {
        val dir = Files.createTempDirectory("share-long-extension").toFile()
        try {
            val name = "😀." + "😀".repeat(90)
            for (n in 1..10) {
                val file = ShareNames.unique(dir, name)
                val suffix = if (n == 1) "" else " ($n)"
                assertTrue(file.name.endsWith(suffix))
                val prefix = file.name.removeSuffix(suffix)
                assertFalse(Character.isHighSurrogate(prefix.last()))
                assertTrue(file.name.toByteArray(Charsets.UTF_8).size <= 255)
                file.writeBytes(byteArrayOf(n.toByte()))
            }
            assertEquals(10, dir.listFiles()!!.size)
        } finally { dir.deleteRecursively() }
    }

    @Test fun fitKeepsTheAspectUnderTheLongSide() {
        assertEquals(1080 to 2400, ShareImages.fit(1080, 2400))
        assertEquals(2560 to 1920, ShareImages.fit(4000, 3000))
        assertEquals(1440 to 2560, ShareImages.fit(3000, 5333))
        assertEquals(2560 to 1, ShareImages.fit(30000, 2))
    }

    @Test fun everyExifOrientationStandsUpright() {
        // EXIF values 1–8; anything else is treated as normal.
        val expected = mapOf(
            1 to ShareImages.Upright(0, false), 2 to ShareImages.Upright(0, true),
            3 to ShareImages.Upright(180, false), 4 to ShareImages.Upright(180, true),
            5 to ShareImages.Upright(90, true), 6 to ShareImages.Upright(90, false),
            7 to ShareImages.Upright(270, true), 8 to ShareImages.Upright(270, false),
            0 to ShareImages.Upright(0, false),
        )
        expected.forEach { (orientation, turn) -> assertEquals("EXIF $orientation", turn, ShareImages.upright(orientation)) }
    }

    @Test fun onlyStillImagesAreScaled() {
        assertTrue(ShareImages.scalable("image/jpeg"))
        assertTrue(ShareImages.scalable("image/heic"))
        assertFalse(ShareImages.scalable("image/gif"))
        assertFalse(ShareImages.scalable("image/svg+xml"))
        assertFalse(ShareImages.scalable("application/pdf"))
        assertFalse(ShareImages.scalable(null))
    }
}
