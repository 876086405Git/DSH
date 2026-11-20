package io.github.ccch1mneyyy.dsh_app.pet

import kotlin.math.roundToInt

/** A rectangle in physical pixels, relative to the rest frame's top-left (the pet's fixed origin). */
data class FramePx(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top

    fun union(o: FramePx) = FramePx(minOf(left, o.left), minOf(top, o.top), maxOf(right, o.right), maxOf(bottom, o.bottom))

    fun contains(o: FramePx) = o.left >= left && o.top >= top && o.right <= right && o.bottom <= bottom

    fun contains(x: Float, y: Float) = x >= left && x < right && y >= top && y < bottom

    /** On screen, with the rest frame's top-left at [rest]. */
    fun at(rest: WindowPos) = ScreenRect(rest.x + left, rest.y + top, rest.x + right, rest.y + bottom)
}

/**
 * The out-of-app pet window's frames (docs/design/pets.md §6.1), in physical pixels around one
 * origin, the rest frame's top-left, so switching between them moves nothing on screen:
 *
 * - **rest**: [restBox] × k, the pack's wide hit box with the idle picture's cell
 *   ([PetPack.windowBox]). Kept small: on Android 12+ an app overlay takes every touch over its whole
 *   frame, transparent pixels included, so a bigger window is a bigger dead spot over other apps;
 * - **held**: rest plus the drag reaction's whole cell. Picked up, the pet is drawn lifted (Deepy's
 *   react-drag body reaches 13.6 art px above the wide box), so while held, and until that
 *   picture is gone, the window grows to hold it;
 * - **grown**: rest plus the cell of any animation the pet can play that reaches past it, while
 *   that animation shows: a jump (Deepy's happy, 13 art px up), a laptop (its typing, 8 left), a
 *   thought cloud (its thinking, 12 up and 8 left), notes and props (music, conducting), Zzz. A cell
 *   is trimmed to what its frames draw, so a union only grows where the art does (Deepy's typing:
 *   8 art px left, and above only the 1 its top row needs) and the window takes no more than the
 *   picture.
 *
 * [reach] is every frame the window can take while docked; the dock keeps all of it on screen and
 * clear of the bars, so a grown frame never has to move the pet. [hit] is where a touch is the
 * pet's: the body, not the air a grown frame adds.
 *
 * Cells are placed as [PetView] draws them: each edge rounded to whole physical pixels, so a box
 * inside another stays inside it at any scale (pixel art's whole k rounds nothing; smooth art's
 * fractional k would otherwise push a cell flush with the rest frame one pixel past it). Pure,
 * for the JVM tests.
 */
class PetFrames(
    val restBox: PetBox,
    val k: Float,
    private val heldAnim: PetAnimation?,
    grownAnims: Collection<PetAnimation> = emptyList(),
    bodyBox: PetBox = restBox,
    /** By animation name: its body hit box ([PetPack.hitBoxFor]). */
    hitBoxes: Map<String, PetBox> = emptyMap(),
    /** A float's fixed viewport around its alpha box; docking reserves it, touch does not. */
    fullReach: FramePx? = null,
) {
    val rest = FramePx(0, 0, (restBox.w * k).roundToInt(), (restBox.h * k).roundToInt())

    /** [box] (canvas px) in physical px around the rest origin, placed as cells are. */
    fun place(box: PetBox): FramePx {
        val x = box.x - restBox.x
        val y = box.y - restBox.y
        return FramePx(
            (x * k).roundToInt(), (y * k).roundToInt(),
            ((x + box.w) * k).roundToInt(), ((y + box.h) * k).roundToInt(),
        )
    }

    /** Where [anim]'s cell is drawn, relative to the rest frame's origin. */
    fun cell(anim: PetAnimation): FramePx = place(anim.box)

    /** The idle body ([PetPack.contentBox]): what a bubble lines up with and points at. */
    val body: FramePx = place(bodyBox)

    /** The picture [shown] makes: the body with that animation's cell (a jump, a cloud, a 「!」). */
    fun art(shown: PetAnimation?): FramePx = shown?.let { body.union(cell(it)) } ?: body

    val held: FramePx = heldAnim?.let { rest.union(cell(it)) } ?: rest

    /** By animation name: the frame each animation reaching past rest gets while it shows. */
    val grown: Map<String, FramePx> = grownAnims
        .filter { it.name != heldAnim?.name }
        .associate { it.name to rest.union(cell(it)) }
        .filterValues { it != rest }

    /** Rest and every grown frame: what a docked pet may need on screen. */
    val reach: FramePx = fullReach ?: grown.values.fold(rest, FramePx::union)

    private val hits: Map<String, FramePx> = hitBoxes.mapValues { (_, box) -> rest.union(place(box)) }

    /**
     * Where a touch counts while [shown] is up: the rest frame (where it always counted) and that
     * animation's body hit box (typing's laptop, react-drag's lifted body). Not the rest of a grown
     * frame: a touch on a thought cloud, Zzz or the air over a jump most likely meant the app
     * underneath, and it can't get there (the window has it), so it does nothing rather than open
     * a chat.
     */
    fun hit(shown: PetAnimation?): FramePx = shown?.let { hits[it.name] } ?: rest

    /**
     * The frame for [shown]: held while [holding] or while the held picture is still up (its
     * successor's sheet may lag), a grown one while its animation shows, else rest.
     */
    fun frameFor(shown: PetAnimation?, holding: Boolean): FramePx = when {
        holding || (heldAnim != null && shown?.name == heldAnim.name) -> held
        shown != null -> grown[shown.name] ?: rest
        else -> rest
    }

    companion object {
        /**
         * Every animation the out-of-app pet may show (roam aside: it doesn't roam) gets a frame
         * that holds its whole cell, and a body to touch.
         */
        fun of(pack: PetPack, restBox: PetBox, k: Float): PetFrames {
            val shown = pack.usedAnimations(skipStates = setOf("roam")).mapNotNull { pack.animations[it] }
            return PetFrames(
                restBox, k, pack.reaction("drag"), shown, pack.contentBox,
                shown.associate { it.name to pack.hitBoxFor(it) },
            )
        }

        /** Window position of [frame] when the rest frame sits at [rest]. */
        fun windowAt(rest: WindowPos, frame: FramePx) = WindowPos(rest.x + frame.left, rest.y + frame.top)

        /** Where the rest frame sits for a window of [frame] at [window]. */
        fun restOf(window: WindowPos, frame: FramePx) = WindowPos(window.x - frame.left, window.y - frame.top)
    }
}
