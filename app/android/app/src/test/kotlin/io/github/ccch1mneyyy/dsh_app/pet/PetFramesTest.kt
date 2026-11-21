package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.Inflater
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor

/**
 * The alpha of a palette PNG (how the bundled sheets are stored: 4- or 8-bit indices with a tRNS
 * table), decoded by hand: unit tests compile against android.jar, without javax.imageio.
 */
private class PaletteAlpha(val width: Int, val height: Int, private val alpha: ByteArray) {
    fun alpha(x: Int, y: Int): Int = alpha[y * width + x].toInt() and 0xff

    companion object {
        fun read(file: File): PaletteAlpha {
            val d = file.readBytes()
            fun int(at: Int) = ((d[at].toInt() and 0xff) shl 24) or ((d[at + 1].toInt() and 0xff) shl 16) or
                ((d[at + 2].toInt() and 0xff) shl 8) or (d[at + 3].toInt() and 0xff)
            var w = 0
            var h = 0
            var depth = 0
            var trns = ByteArray(0)
            val idat = ByteArrayOutputStream()
            var i = 8
            while (i < d.size) {
                val n = int(i)
                when (String(d, i + 4, 4, Charsets.US_ASCII)) {
                    "IHDR" -> {
                        w = int(i + 8)
                        h = int(i + 12)
                        depth = d[i + 16].toInt()
                        check(d[i + 17].toInt() == 3 && d[i + 20].toInt() == 0) { "${file.name}: not a plain palette PNG" }
                    }
                    "tRNS" -> trns = d.copyOfRange(i + 8, i + 8 + n)
                    "IDAT" -> idat.write(d, i + 8, n)
                }
                i += 12 + n
            }
            val stride = (w * depth + 7) / 8
            val raw = ByteArray(h * (stride + 1))
            Inflater().run {
                setInput(idat.toByteArray())
                var got = 0
                while (got < raw.size && !finished()) got += inflate(raw, got, raw.size - got)
                end()
            }
            val out = ByteArray(w * h)
            var prev = ByteArray(stride)
            for (y in 0 until h) {
                val row = raw.copyOfRange(y * (stride + 1) + 1, (y + 1) * (stride + 1))
                val filter = raw[y * (stride + 1)].toInt()
                for (x in 0 until stride) {
                    val a = if (x > 0) row[x - 1].toInt() and 0xff else 0
                    val b = prev[x].toInt() and 0xff
                    val c = if (x > 0) prev[x - 1].toInt() and 0xff else 0
                    val add = when (filter) {
                        1 -> a
                        2 -> b
                        3 -> (a + b) / 2
                        4 -> {
                            val p = a + b - c
                            val pa = abs(p - a)
                            val pb = abs(p - b)
                            val pc = abs(p - c)
                            if (pa <= pb && pa <= pc) a else if (pb <= pc) b else c
                        }
                        else -> 0
                    }
                    row[x] = ((row[x].toInt() and 0xff) + add).toByte()
                }
                for (x in 0 until w) {
                    val index = if (depth == 8) {
                        row[x].toInt() and 0xff
                    } else {
                        val perByte = 8 / depth
                        val shift = 8 - depth * (x % perByte + 1)
                        ((row[x / perByte].toInt() and 0xff) shr shift) and ((1 shl depth) - 1)
                    }
                    out[y * w + x] = if (index < trns.size) trns[index] else 0xff.toByte()
                }
                prev = row
            }
            return PaletteAlpha(w, h, out)
        }
    }
}


/**
 * The out-of-app window's frames (rest, held around the lifted pose, grown around every animation
 * that reaches past rest), where they are touched, and their placement.
 */
class PetFramesTest {
    private fun packDir(id: String): File? =
        generateSequence(File("").absoluteFile) { it.parentFile }
            .flatMap { sequenceOf(File(it, "app/assets/pets/$id"), File(it, "assets/pets/$id")) }
            .firstOrNull { File(it, "pack.json").isFile }

    private fun shipped(id: String): PetPack {
        val dir = packDir(id)
        assertNotNull("bundled pack $id", dir)
        return PetPack.parse(File(dir, "pack.json").readText())
    }

    /** Every bundled pack: each directory under assets/pets with a pack.json. */
    private val packs: List<String> by lazy {
        val root = packDir("deepy-whale")?.parentFile
        assertNotNull("bundled packs", root)
        root!!.listFiles().orEmpty().filter { File(it, "pack.json").isFile }.map { it.name }.sorted().also {
            assertTrue("both bundled pets at least: $it", it.containsAll(listOf("deepy-whale", "whale-girl")))
        }
    }

    private fun frames(p: PetPack, size: String = "medium", density: Float = 2.75f) =
        PetFrames.of(p, p.windowBox(), p.screenScale(PetSize.fromName(size), density))

    /** What the out-of-app pet may show, but the drag pose (held): every state's, tier's, bonus, idle action and reaction; not roam's. */
    private fun shownAnims(p: PetPack) =
        p.usedAnimations(skipStates = setOf("roam")).map { p.animations.getValue(it) }.filter { it.name != p.reaction("drag")?.name }

    /** Per pack and animation: the visible pixels of all its frames, in cell (sheet) px, [l, t, r, b). */
    private val opaqueCache = HashMap<String, IntArray>()

    private fun opaque(id: String, a: PetAnimation): IntArray = opaqueCache.getOrPut("$id/${a.name}") {
        val sheet = PaletteAlpha.read(File(packDir(id), a.sheet))
        val b = intArrayOf(Int.MAX_VALUE, Int.MAX_VALUE, Int.MIN_VALUE, Int.MIN_VALUE)
        for (cell in a.frames.map { it.cell }.toSet()) {
            val ox = (cell % a.cols) * a.frameW
            val oy = (cell / a.cols) * a.frameH
            assertTrue("$id ${a.name} cell $cell inside ${a.sheet}", ox + a.frameW <= sheet.width && oy + a.frameH <= sheet.height)
            for (y in 0 until a.frameH) for (x in 0 until a.frameW) {
                if (sheet.alpha(ox + x, oy + y) == 0) continue
                b[0] = minOf(b[0], x)
                b[1] = minOf(b[1], y)
                b[2] = maxOf(b[2], x + 1)
                b[3] = maxOf(b[3], y + 1)
            }
        }
        assertTrue("$id ${a.name} draws something", b[2] > b[0])
        b
    }

    /**
     * Against the art itself: the visible pixels of every frame of [a], in physical px around the
     * rest origin, as PetView's drawBitmap(src, dst) scales the cell into [PetFrames.cell].
     */
    private fun drawn(id: String, a: PetAnimation, f: PetFrames): FramePx {
        val dst = f.cell(a)
        val o = opaque(id, a)
        val sx = dst.width.toDouble() / a.frameW
        val sy = dst.height.toDouble() / a.frameH
        // Outwards to whole pixels (a pixel partly covered is drawn), past float noise on exact edges.
        fun out(v: Double, up: Boolean) = (if (up) ceil(v - 1e-6) else floor(v + 1e-6)).toInt()
        return FramePx(
            out(dst.left + o[0] * sx, false), out(dst.top + o[1] * sy, false),
            out(dst.left + o[2] * sx, true), out(dst.top + o[3] * sy, true),
        )
    }

    // A 1080×2400 phone: 96 px status bar, 63 px gesture bar (as EdgeSnapTest).
    private val portrait = SafeArea(1080, 2400, left = 0, top = 96, right = 0, bottom = 63)

    /** The held bug: picked up, Deepy is drawn 14 art px higher than the window ever reached. */
    @Test fun deepyHeldGrowsUpwardsAroundTheLiftedPose() {
        val p = shipped("deepy-whale")
        val drag = p.reaction("drag")!!
        assertEquals("react-drag", drag.name)
        // Rest: wide hit box (8, 18, 44 × 31) with the idle cell's shadow row → 44 × 32 art px.
        assertEquals(PetBox(8f, 18f, 44f, 32f), p.windowBox())
        // Medium on a 2.75 phone: the app's 4 whole px per art px (petDevicePixels).
        val f = frames(p)
        assertEquals(FramePx(0, 0, 176, 128), f.rest)
        // react-drag's cell starts at y 4: (4 − 18) × 4 = 56 px above the rest frame.
        assertEquals(FramePx(8, -56, 172, 128), f.cell(drag))
        assertFalse(f.rest.contains(f.cell(drag)))
        assertEquals(FramePx(0, -56, 176, 128), f.held)
        assertTrue(f.held.contains(f.rest))
        assertTrue(f.held.contains(f.cell(drag)))
    }

    @Test fun girlHeldGrowsLeftAndUp() {
        val p = shipped("whale-girl")
        val drag = p.reaction("drag")!!
        assertEquals(PetBox(10f, 12f, 54f, 49f), p.windowBox())
        // Crisp: 2 px per art px. drag reaches 5 art px left and 2 up of the rest frame.
        val f = frames(p)
        assertEquals(FramePx(0, 0, 108, 98), f.rest)
        assertEquals(FramePx(-10, -4, 108, 98), f.cell(drag))
        assertEquals(FramePx(-10, -4, 108, 98), f.held)
    }

    /**
     * The bug (群友, 11-01): out of the app, thinking's cloud and juggling's notes and props were cut
     * off. Only happy, waking and typing had their own frame; everything else drew into the rest
     * frame, and this much of the art (medium on a 2.75 phone) fell outside it.
     */
    @Test fun thinkingAndJugglingWereCutAtRest() {
        val deepy = shipped("deepy-whale")
        val d = frames(deepy)
        assertEquals(FramePx(0, 0, 176, 128), d.rest)
        // thinking: the cloud 45 px (11.2 art px) over the rest frame's top and 31 px (7.6) left of it.
        assertEquals(FramePx(-31, -45, 155, 128), drawn("deepy-whale", deepy.primary("thinking", 0), d))
        // juggling, one sub-agent: music, 32 px up and 24 left; two or more: conducting, 72 up and 28 left.
        assertEquals(FramePx(-24, -32, 168, 128), drawn("deepy-whale", deepy.primary("juggling", 1), d))
        assertEquals(FramePx(-28, -72, 176, 128), drawn("deepy-whale", deepy.primary("juggling", 2), d))
        val girl = shipped("whale-girl")
        val g = frames(girl)
        assertEquals(FramePx(0, 0, 108, 98), g.rest)
        // thinking: 22 px (11 art px) up and 6 right; conducting 22 up, 20 left, 8 right; music 4 left, 2 up.
        assertEquals(FramePx(4, -22, 114, 98), drawn("whale-girl", girl.primary("thinking", 0), g))
        assertEquals(FramePx(-20, -22, 116, 98), drawn("whale-girl", girl.primary("juggling", 2), g))
        assertEquals(FramePx(-4, -2, 106, 98), drawn("whale-girl", girl.primary("juggling", 1), g))
        // Now each is whole in the frame the window takes for it.
        for ((id, p, f) in listOf(Triple("deepy-whale", deepy, d), Triple("whale-girl", girl, g))) {
            for (a in listOf(p.primary("thinking", 0), p.primary("juggling", 1), p.primary("juggling", 2))) {
                val art = drawn(id, a, f)
                assertFalse("$id ${a.name} cut at rest", f.rest.contains(art))
                assertTrue("$id ${a.name} whole", f.frameFor(a, holding = false).contains(art))
            }
        }
    }

    /** Deepy: each animation grows only where its art reaches past the rest frame. */
    @Test fun deepyGrowsOnlyWhereEachAnimationNeedsIt() {
        val p = shipped("deepy-whale")
        val f = frames(p)
        // typing: the laptop, 8 art px left (32 px); above only its top row's 1 art px; right and bottom as at rest.
        assertEquals(FramePx(-32, -4, 176, 128), f.grown["typing"])
        // happy jumps 13 art px up and reaches 8 left; waking jumps 14 up (its last row rounds 1 px below).
        assertEquals(FramePx(-32, -52, 176, 128), f.grown["happy"])
        assertEquals(FramePx(0, -56, 176, 128), f.grown["waking"])
        // thinking's cloud: 12 art px up, 8 left; music 8 up, 6 left; conducting and building 18 up.
        assertEquals(FramePx(-32, -48, 176, 128), f.grown["thinking"])
        assertEquals(FramePx(-24, -32, 176, 128), f.grown["music"])
        assertEquals(FramePx(-28, -72, 176, 128), f.grown["conducting"])
        assertEquals(FramePx(-24, -72, 176, 128), f.grown["building"])
        // Zzz: 16 art px up, 6 left.
        assertEquals(FramePx(-24, -64, 176, 128), f.grown["sleeping"])
        // Inside rest already: no frame of its own. The drag pose has held instead.
        assertNull(f.grown["carrying"])
        assertNull(f.grown["idle"])
        assertNull(f.grown["react-drag"])
        // Docked, room for all of it: 16 px more above than for happy / waking / typing alone, no more to the left.
        assertEquals(FramePx(-32, -72, 176, 128), f.reach)
        assertEquals(f.grown["music"], f.frameFor(p.primary("working", 2), holding = false))
    }

    @Test fun girlGrowsOnlyWhereEachAnimationNeedsIt() {
        val p = shipped("whale-girl")
        val f = frames(p)
        // typing: what it shows above her head reaches 8 art px up, and nothing reaches past rest elsewhere.
        assertEquals(FramePx(0, -16, 108, 98), f.grown["typing"])
        assertEquals(FramePx(-10, -12, 108, 98), f.grown["happy"])
        assertEquals(FramePx(-2, -2, 108, 98), f.grown["waking"])
        // thinking: 11 art px up and 3 right; conducting 11 up, 10 left and 4 right; carrying only left.
        assertEquals(FramePx(0, -22, 114, 98), f.grown["thinking"])
        assertEquals(FramePx(-20, -22, 116, 98), f.grown["conducting"])
        assertEquals(FramePx(-20, 0, 108, 98), f.grown["carrying"])
        // The attention extras, not just happy.
        assertEquals(FramePx(-6, -2, 108, 98), f.grown["smile-hearts"])
        assertEquals(FramePx(-20, -22, 116, 98), f.reach)
    }

    /** Every size on several screens: idle whole at rest, the drag pose whole while held, every other animation in its frame. */
    @Test fun everyFrameHoldsItsCell() {
        for (id in packs) {
            val p = shipped(id)
            for (size in listOf("small", "medium", "large")) {
                for (density in listOf(1.5f, 2f, 2.625f, 2.75f, 3f, 3.5f)) {
                    val f = frames(p, size, density)
                    val where = "$id $size @$density"
                    assertTrue("$where idle", f.rest.contains(f.cell(p.primary(PetPack.IDLE, 0))))
                    assertTrue("$where drag", f.held.contains(f.cell(p.reaction("drag")!!)))
                    assertTrue("$where rest ⊂ held", f.held.contains(f.rest))
                    for (a in shownAnims(p)) {
                        val g = f.frameFor(a, holding = false)
                        assertEquals("$where ${a.name}", f.rest.union(f.cell(a)), g)
                        assertTrue("$where ${a.name} ⊂ reach", f.reach.contains(g))
                    }
                    assertEquals(where, 0, f.rest.left)
                    assertEquals(where, 0, f.rest.top)
                }
            }
        }
    }

    /**
     * Against the art: every visible pixel of every react-drag / drag frame lands inside the held
     * frame, and for Deepy a good part of the body was above the rest frame.
     */
    @Test fun everyDragPixelIsInsideTheHeldFrame() {
        for (id in packs) {
            val p = shipped(id)
            val f = frames(p)
            val d = drawn(id, p.reaction("drag")!!, f)
            assertTrue("$id: $d in ${f.held}", f.held.contains(d))
            assertFalse("$id: $d would be cut at rest ${f.rest}", f.rest.contains(d))
            if (id == "deepy-whale") assertTrue("Deepy's lifted head: $d", d.top <= -50)
        }
    }

    /**
     * Against the art, for every bundled pack, every animation the pet may show out of the app,
     * every size, several screens: every visible pixel of every frame lands inside the cell PetView
     * draws it in, the window frame it shows in, the docked reach and the picture the bubble keeps
     * clear of. And the frame reaches past rest on a side only as far as the art does (within one
     * art px of rounding), so the dead spot over other apps grows no more than it must.
     */
    @Test fun everyAnimationIsWholeAndGrowsOnlyWhereNeeded() {
        for (id in packs) {
            val p = shipped(id)
            for (size in listOf("small", "medium", "large")) for (density in listOf(2f, 2.75f, 3.5f)) {
                val f = frames(p, size, density)
                val k = ceil(f.k.toDouble()).toInt()
                for (a in shownAnims(p) + p.reaction("drag")!!) {
                    val held = a.name == p.reaction("drag")?.name
                    val g = f.frameFor(a, holding = false)
                    val d = drawn(id, a, f)
                    val where = "$id $size @$density ${a.name}: drawn $d, frame $g, rest ${f.rest}"
                    assertTrue("$where (cell)", f.cell(a).contains(d))
                    assertTrue("$where (window)", g.contains(d))
                    assertTrue("$where (bubble's picture)", f.art(a).contains(d))
                    if (held) {
                        assertEquals(where, f.held, g)
                        continue
                    }
                    assertTrue("$where (reach)", f.reach.contains(g))
                    // Grown exactly when the art would be cut at rest.
                    assertEquals("$where (grown iff cut)", !f.rest.contains(d), a.name in f.grown)
                    // Per side: as at rest unless the art reaches past it there, and then no further than the art.
                    if (g.left < 0) assertTrue("$where left", d.left < 0 && d.left - g.left <= k) else assertEquals(where, 0, g.left)
                    if (g.top < 0) assertTrue("$where top", d.top < 0 && d.top - g.top <= k) else assertEquals(where, 0, g.top)
                    if (g.right > f.rest.right) assertTrue("$where right", d.right > f.rest.right && g.right - d.right <= k) else assertEquals(where, f.rest.right, g.right)
                    if (g.bottom > f.rest.bottom) assertTrue("$where bottom", d.bottom > f.rest.bottom && g.bottom - d.bottom <= k) else assertEquals(where, f.rest.bottom, g.bottom)
                }
            }
        }
    }

    /**
     * Touch stays on the body: a grown window draws the cloud, the Zzz and the air over a jump but
     * doesn't take them as the pet's. The rest frame always counts, as it always did.
     */
    @Test fun touchesCountOnTheBodyOnly() {
        for (id in packs) {
            val p = shipped(id)
            for (size in listOf("small", "medium", "large")) {
                val f = frames(p, size)
                for (a in shownAnims(p) + p.reaction("drag")!!) {
                    val hit = f.hit(a)
                    val where = "$id $size ${a.name}: hit $hit"
                    assertTrue("$where ⊇ rest", hit.contains(f.rest))
                    assertTrue("$where ⊂ window", f.frameFor(a, holding = false).contains(hit))
                    assertEquals(where, f.rest.union(f.place(p.hitBoxFor(a))), hit)
                }
                assertEquals(f.rest, f.hit(null))
            }
        }
        val p = shipped("deepy-whale")
        val f = frames(p)
        // thinking: the whole cloud shows, none of it is a target.
        val thinking = p.primary("thinking", 0)
        assertEquals(f.rest, f.hit(thinking))
        val cloud = drawn("deepy-whale", thinking, f)
        assertTrue(f.frameFor(thinking, holding = false).contains(cloud.left + 1f, cloud.top + 1f))
        assertFalse(f.hit(thinking).contains(cloud.left + 1f, cloud.top + 1f))
        // happy: the air over the rest frame isn't the pet's either (the chat page hit-tests the wide box too).
        assertEquals(f.rest, f.hit(p.primary("attention", 0)))
        // typing: the laptop is (byAnim typing reaches x 0), as on the chat page.
        val typing = p.primary("working", 1)
        assertEquals(FramePx(-32, 0, 176, 128), f.hit(typing))
        assertTrue(f.hit(typing).contains(-16f, 60f))
        // Put down before the state's sheet is back: the lifted body (byAnim react-drag) still counts.
        assertEquals(FramePx(0, -48, 176, 128), f.hit(p.reaction("drag")))
    }

    @Test fun tappingTheSleepingFishKeepsItsOutgoingPixelsUntilTheBlendEnds() {
        val p = shipped("pink-fish")
        val f = frames(p, density = 3f)
        val sleep = p.primary("sleeping", 0)
        val poke = p.reaction("tapLeft")!!
        val player = PetPlayer()
        player.setState(sleep, listOf(PetIdleItem(sleep, sleep.totalMs, 1)), null, 0L)
        val outgoing = player.frame(0L)!!.anim
        player.react(poke, loop = false, now = 1L)
        val shown = player.frame(1L)!!.anim
        assertEquals(sleep, outgoing)
        assertEquals(poke, shown)
        assertFalse(p.pixelArt)

        // Sleep's actual art reaches beyond poke's rest window on both sides.
        val asleep = drawn("pink-fish", outgoing, f)
        assertFalse(f.frameFor(shown, holding = false).contains(asleep))
        val during = f.frameFor(shown, holding = false, fadingFrom = outgoing)
        assertTrue(during.contains(asleep))
        assertTrue(during.contains(f.cell(shown)))
        // Once the outgoing picture is gone, do not keep its extra touch-blocking area.
        assertEquals(f.rest, f.frameFor(shown, holding = false, fadingFrom = null))
    }

    @Test fun eachFrameLastsWhileItsPictureIsUp() {
        val p = shipped("deepy-whale")
        val f = frames(p)
        val idle = p.primary(PetPack.IDLE, 0)
        val drag = p.reaction("drag")!!
        val typing = p.animations.getValue("typing")
        assertEquals(f.held, f.frameFor(idle, holding = true))
        assertEquals(f.held, f.frameFor(typing, holding = true))
        assertEquals(f.held, f.frameFor(null, holding = true))
        // Let go while the state's sheet is still decoding: the lifted picture is still up.
        assertEquals(f.held, f.frameFor(drag, holding = false))
        assertEquals(f.grown["typing"], f.frameFor(typing, holding = false))
        assertEquals(f.grown["happy"], f.frameFor(p.primary("attention", 0), holding = false))
        assertEquals(f.rest, f.frameFor(idle, holding = false))
        assertEquals(f.rest, f.frameFor(null, holding = false))
        // A tap's reaction and thinking's cloud now get theirs too.
        assertEquals(f.grown.getValue("react-left"), f.frameFor(p.reaction("tapLeft"), holding = false))
        assertEquals(f.grown.getValue("thinking"), f.frameFor(p.primary("thinking", 0), holding = false))
        assertEquals(f.grown.getValue("idle-look"), f.frameFor(p.animations.getValue("idle-look"), holding = false))
    }

    @Test fun aPackWithoutADragReactionOrGrownStatesNeverGrows() {
        val p = shipped("deepy-whale")
        val f = PetFrames(p.windowBox(), 3.75f, heldAnim = null)
        assertEquals(f.rest, f.held)
        assertEquals(f.rest, f.reach)
        assertEquals(f.rest, f.frameFor(p.reaction("drag"), holding = true))
        assertEquals(f.rest, f.frameFor(p.animations.getValue("typing"), holding = false))
    }

    /** Growing and shrinking moves nothing: a cell lands on the same screen pixels in every frame. */
    @Test fun theAnchorStaysPutAcrossFrames() {
        val p = shipped("deepy-whale")
        val f = frames(p)
        val rest = WindowPos(907, 1405)
        val all = listOf(f.rest, f.held) + f.grown.values
        for (anim in listOf(p.primary(PetPack.IDLE, 0), p.reaction("drag")!!) + shownAnims(p)) {
            val cell = f.cell(anim)
            val screens = all.map { frame ->
                val window = PetFrames.windowAt(rest, frame)
                // PetView draws the cell at (cell − frame origin) inside the window.
                WindowPos(window.x + cell.left - frame.left, window.y + cell.top - frame.top)
            }.toSet()
            assertEquals(anim.name, setOf(WindowPos(rest.x + cell.left, rest.y + cell.top)), screens)
        }
        for (frame in all) assertEquals(rest, PetFrames.restOf(PetFrames.windowAt(rest, frame), frame))
        assertEquals(WindowPos(907, 1405 - 56), PetFrames.windowAt(rest, f.held))
        assertEquals(WindowPos(907 - 32, 1405 - 4), PetFrames.windowAt(rest, f.grown.getValue("typing")))
    }

    /**
     * Docked anywhere, every frame the window may take there (typing's laptop, happy's jump,
     * thinking's cloud, conducting's props) is inside the margins: no frame has to move the pet, none
     * reaches under a bar or off the screen, so nothing drawn is cut by the screen's edge either.
     */
    @Test fun theDockLeavesRoomForEveryGrownFrame() {
        val landscape = SafeArea(2400, 1080, left = 96, top = 0, right = 0, bottom = 63)
        for (id in packs) {
            val p = shipped(id)
            for (size in listOf("small", "medium", "large")) {
                val f = frames(p, size, 2.75f)
                for (area in listOf(portrait, landscape)) {
                    val m = 22
                    for (side in Side.values()) for (y in listOf(0f, 0.37f, 1f)) {
                        val dock = Dock(side, y)
                        val rest = EdgeSnap.position(dock, f.reach, area, m)
                        for (frame in listOf(f.rest) + f.grown.values) {
                            val w = PetFrames.windowAt(rest, frame)
                            val where = "$id $size $dock $area: $frame at $w"
                            assertTrue(where, w.x >= area.left + m && w.x + frame.width <= area.screenW - area.right - m)
                            assertTrue(where, w.y >= area.top + m && w.y + frame.height <= area.screenH - area.bottom - m)
                        }
                        // Released where it docked: the same dock back.
                        val again = EdgeSnap.dockFor(rest, f.rest.width, f.reach, area, m)
                        assertEquals(dock.side, again.side)
                        assertEquals(y, again.yFraction, 0.01f)
                    }
                }
            }
        }
    }

    /** With nothing past the rest frame, the dock is exactly what it was. */
    @Test fun aRestOnlyReachDocksAsBefore() {
        val w = 165
        val h = 120
        val reach = FramePx(0, 0, w, h)
        for (side in Side.values()) for (y in listOf(0f, 0.5f, 1f)) {
            val dock = Dock(side, y)
            assertEquals(EdgeSnap.position(dock, w, h, portrait, 22), EdgeSnap.position(dock, reach, portrait, 22))
        }
        for ((x, y) in listOf(10 to 300, 900 to 1200, 500 to 5000)) {
            assertEquals(EdgeSnap.dockFor(x, y, w, h, portrait, 22, 300f), EdgeSnap.dockFor(WindowPos(x, y), w, reach, portrait, 22, 300f))
        }
    }

    /** Away from the edges, held follows the finger exactly: the dock on release is as before. */
    @Test fun heldFollowsTheFingerAndReleasesWhereTheRestFrameIs() {
        val f = frames(shipped("deepy-whale"))
        val start = WindowPos(400, 1200)
        val window = EdgeSnap.carry(start, -120, 300, f.held, portrait)
        assertEquals(WindowPos(400 - 120, 1200 + 300 - 56), window)
        val rest = PetFrames.restOf(window, f.held)
        assertEquals(WindowPos(280, 1500), rest)
        val old = EdgeSnap.clampDrag(start.x - 120, start.y + 300, f.rest.width, f.rest.height, portrait)
        assertEquals(old, rest)
    }

    /** At every edge the whole held window, lifted head and all, stays on screen and clear of the bars. */
    @Test fun heldStaysWholeOnScreenAtTheEdges() {
        val f = frames(shipped("deepy-whale"))
        val m = 22
        val top = EdgeSnap.position(Dock(Side.RIGHT, 0f), f.reach, portrait, m)
        for ((dx, dy) in listOf(0 to 0, 0 to -3000, 3000 to 0, -3000 to 0, 0 to 3000, -3000 to -3000, 3000 to 3000)) {
            val w = EdgeSnap.carry(top, dx, dy, f.held, portrait)
            val where = "($dx, $dy) → $w"
            assertTrue(where, w.x >= 0 && w.x + f.held.width <= portrait.screenW)
            assertTrue(where, w.y >= portrait.top && w.y + f.held.height <= portrait.screenH - portrait.bottom)
        }
        // Pinned to the top, the rest frame sits 56 px lower than the window, so the head shows.
        val pinned = EdgeSnap.carry(top, 0, -3000, f.held, portrait)
        assertEquals(portrait.top, pinned.y)
        assertEquals(portrait.top + 56, PetFrames.restOf(pinned, f.held).y)
        // The release reads where the finger put the rest frame (as before the window grew), so the
        // top dock is still reachable.
        val drop = EdgeSnap.clampDrag(top.x, top.y - 3000, f.rest.width, f.rest.height, portrait)
        val dock = EdgeSnap.dockFor(drop, f.rest.width, f.reach, portrait, m)
        assertEquals(Side.RIGHT, dock.side)
        assertEquals(0f, dock.yFraction)
    }

    /** Dragged into a corner on the left: the held window stops at the screen edge, no part cut. */
    @Test fun girlHeldAtTheLeftEdgeKeepsItsSwingingSide() {
        val f = frames(shipped("whale-girl"))
        // drag reaches 10 px left of the rest frame: pushed against x 0, the rest frame stops at 10.
        val w = EdgeSnap.carry(WindowPos(300, 1000), -3000, 0, f.held, portrait)
        assertEquals(0, w.x)
        assertEquals(10, PetFrames.restOf(w, f.held).x)
    }
}
