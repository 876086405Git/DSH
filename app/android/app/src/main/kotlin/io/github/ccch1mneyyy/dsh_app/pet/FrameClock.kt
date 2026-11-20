package io.github.ccch1mneyyy.dsh_app.pet

import kotlin.random.Random

/** Which frame of an animation shows at a given time, by the pack's per-frame times. */
object FrameClock {
    /** Index into [PetAnimation.frames] at [elapsedMs] since the animation started. */
    fun frameAt(anim: PetAnimation, elapsedMs: Long): Int {
        val total = anim.totalMs
        if (total <= 0) return 0
        if (!anim.loop && elapsedMs >= total) return anim.frames.lastIndex
        var t = if (elapsedMs < 0) 0 else elapsedMs % total
        for ((i, f) in anim.frames.withIndex()) {
            if (t < f.ms) return i
            t -= f.ms
        }
        return anim.frames.lastIndex
    }

    /** Elapsed time of the next frame change after [elapsedMs]; null when a one-shot is done. */
    fun nextBoundary(anim: PetAnimation, elapsedMs: Long): Long? {
        val total = anim.totalMs
        if (total <= 0) return null
        val e = elapsedMs.coerceAtLeast(0)
        if (!anim.loop && e >= total) return null
        val cycle = e / total
        var t = cycle * total
        for (f in anim.frames) {
            t += f.ms
            if (t > e) return t
        }
        return (cycle + 1) * total
    }

    /** Milliseconds until the picture next changes, or null. Frames that repeat a cell don't count. */
    fun nextChange(anim: PetAnimation, elapsedMs: Long): Long? {
        val now = frameAt(anim, elapsedMs)
        var t = elapsedMs
        repeat(anim.frames.size) {
            val b = nextBoundary(anim, t) ?: return null
            if (anim.frames[frameAt(anim, b)].cell != anim.frames[now].cell) return b - elapsedMs
            t = b
        }
        return nextBoundary(anim, elapsedMs)?.minus(elapsedMs)
    }
}

/**
 * When idle plays something: a still frame, and every 8–15 s one idle
 * action from the pool, picked by weight. Saves power without the stutter of a lower frame rate.
 */
class IdleRhythm(private val random: Random = Random.Default) {
    fun nextDelayMs(): Long = MIN_GAP_MS + random.nextLong(MAX_GAP_MS - MIN_GAP_MS + 1)

    fun pick(pool: List<PetIdleItem>): PetIdleItem? {
        if (pool.isEmpty()) return null
        var r = random.nextInt(pool.sumOf { it.weight })
        for (item in pool) {
            if (r < item.weight) return item
            r -= item.weight
        }
        return pool.last()
    }

    companion object {
        const val MIN_GAP_MS = 8_000L
        const val MAX_GAP_MS = 15_000L
    }
}

/**
 * What the out-of-app pet shows over time, for one state at a time:
 *
 * - **calm** states (idle, sleeping): the still first frame of the primary, and every
 *   [IdleRhythm] gap one action from [calmPool] for its time;
 * - other states: their animation at full speed; a [PetBonus] drawn on entering plays first for
 *   its one-off time (`PetPack.playMsOf`), then the state's own animation from its first frame;
 * - a reaction (drag, a tap) plays on top and then gives the state back;
 * - [still] (system animations off): first frame without per-frame scheduling; a one-shot
 *   reaction still schedules its return to the state when its time ends.
 *
 * [frame] says what to draw now and how long until the picture changes, so the caller only
 * wakes up then.
 */
class PetPlayer(private val random: Random = Random.Default) {
    data class Frame(val anim: PetAnimation, val index: Int, val nextInMs: Long?)

    private val rhythm = IdleRhythm(random)
    private var primary: PetAnimation? = null
    private var calm = false
    private var calmPool: List<PetIdleItem> = emptyList()
    private var playing: PetAnimation? = null
    private var playStart = 0L
    private var playUntil = Long.MAX_VALUE
    private var nextPlayAt = Long.MAX_VALUE
    private var reaction: PetAnimation? = null
    private var reactionStart = 0L
    private var reactionLoops = false

    var still = false

    /** Starts [primary] for a state; [calmPool] non-null makes it a calm state. */
    fun setState(
        primary: PetAnimation,
        calmPool: List<PetIdleItem>?,
        bonus: PetBonus?,
        now: Long,
        playMs: (PetAnimation) -> Long = { if (it.loop) 2 * it.totalMs else it.totalMs },
    ) {
        this.primary = primary
        calm = calmPool != null
        this.calmPool = calmPool.orEmpty()
        if (calm) {
            playing = null
            nextPlayAt = now + rhythm.nextDelayMs()
        } else {
            val b = bonus?.takeIf { it.anims.isNotEmpty() && random.nextFloat() < it.chance }
            val variant = b?.anims?.get(random.nextInt(b.anims.size))
            playing = variant ?: primary
            playStart = now
            playUntil = if (variant != null) now + playMs(variant) else Long.MAX_VALUE
        }
    }

    fun react(anim: PetAnimation, loop: Boolean, now: Long) {
        reaction = anim
        reactionStart = now
        reactionLoops = loop
    }

    fun endReaction() {
        reaction = null
    }

    val reacting: Boolean get() = reaction != null

    fun frame(now: Long): Frame? {
        reaction?.let { r ->
            val e = now - reactionStart
            if (reactionLoops || e < r.totalMs) {
                val end = if (reactionLoops) null else r.totalMs - e
                if (still) return Frame(r, 0, end)
                val next = FrameClock.nextChange(r, e)
                return Frame(r, FrameClock.frameAt(r, e), listOfNotNull(next, end).minOrNull())
            }
            reaction = null
        }
        val p = primary ?: return null
        if (!calm) {
            if (playing !== p && now >= playUntil) {
                playing = p
                playStart = playUntil
                playUntil = Long.MAX_VALUE
            }
            val a = playing ?: p
            val end = if (playUntil == Long.MAX_VALUE) null else playUntil - now
            if (still) return Frame(a, 0, end)
            val e = now - playStart
            return Frame(a, FrameClock.frameAt(a, e), listOfNotNull(FrameClock.nextChange(a, e), end).minOrNull())
        }
        if (still) return Frame(p, 0, null)
        playing?.let { a ->
            if (now < playUntil) {
                val e = now - playStart
                val next = listOfNotNull(FrameClock.nextChange(a, e), playUntil - now).minOrNull()
                return Frame(a, FrameClock.frameAt(a, e), next)
            }
            playing = null
            nextPlayAt = now + rhythm.nextDelayMs()
        }
        if (now >= nextPlayAt) {
            val item = rhythm.pick(calmPool)
            if (item != null) {
                playing = item.anim
                playStart = now
                playUntil = now + item.ms
                return frame(now)
            }
            nextPlayAt = now + rhythm.nextDelayMs()
        }
        return Frame(p, 0, nextPlayAt - now)
    }
}
