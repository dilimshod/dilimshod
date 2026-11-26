package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min

// On-device HEURISTIC distinction of a traffic police officer (YHXX xodimi) and a road worker (yo‘l ishchisi) among the
// detector's "person" boxes, from the colour of the high-visibility vest on the torso:
//  - fluorescent yellow-green / lime vest (hue ≈ 55–95°, S ≥ 0.5, V ≥ 0.6) over a dark uniform → traffic officer;
//  - fluorescent orange / red-orange vest (hue ≈ 10–35°, S ≥ 0.6, V ≥ 0.55) → road worker
//    (a lime vest without any dark clothing is also treated as a road worker);
//  - otherwise → pedestrian.
// The tracker votes over several frames, and the app marks the role as "≈" (colour heuristic).

/** Role of a detected person (colour heuristic, see [PersonRoleClassifier]). */
enum class PersonRole(val raw: String) {
    PEDESTRIAN("pedestrian"),
    /** Traffic police officer (YHXX xodimi / сотрудник ГАИ) — lime / yellow hi-vis vest over a dark uniform. */
    TRAFFIC_OFFICER("trafficOfficer"),
    /** Road worker (yo‘l ishchisi / дорожный рабочий) — orange hi-vis vest. */
    ROAD_WORKER("roadWorker");

    /** Officers and workers are on the road deliberately: never reported as "yield to the pedestrian". */
    val isRoadStaff: Boolean get() = this != PEDESTRIAN

    companion object {
        fun fromRaw(raw: String): PersonRole? = entries.firstOrNull { it.raw == raw }
    }
}

/** Colour shares measured in a person box. */
data class PersonRoleSample(
    /** Lime / yellow-green vest pixels / sampled torso pixels. */
    val limeShare: Double,
    /** Orange vest pixels / sampled torso pixels. */
    val orangeShare: Double,
    /** Dark pixels (uniform) / sampled pixels of the whole box. */
    val darkShare: Double,
    val torsoPixels: Int,
)

object PersonRoleClassifier {
    /** Torso band of the box: rows from 22 % to 62 % of the box height… */
    const val torsoTop = 0.22
    const val torsoBottom = 0.62
    /** …and the central 60 % of its width. */
    const val torsoWidth = 0.6
    /** Minimum vest share of the torso pixels. */
    const val minVestShare = 0.12
    /** Minimum share of dark pixels in the box for an officer (dark uniform). */
    const val minDarkShare = 0.08
    /** Minimum number of sampled torso pixels for a decision. */
    const val minTorsoPixels = 12
    /** Boxes smaller than this (pixels of height) are not classified. */
    const val minBoxHeightPixels = 40

    internal enum class PixelClass { LIME, ORANGE, DARK, OTHER }

    /** Colour class of one pixel. */
    internal fun pixelClass(p: RGBPixel): PixelClass {
        val r = p.r / 255.0; val g = p.g / 255.0; val b = p.b / 255.0
        val maxC = maxOf(r, g, b); val minC = minOf(r, g, b)
        val delta = maxC - minC
        val value = maxC
        if (value < 0.3) return PixelClass.DARK
        val saturation = if (maxC > 0) delta / maxC else 0.0
        if (delta <= 0) return PixelClass.OTHER
        val hue = hsvHue(r, g, b, maxC, delta)
        if (hue >= 55 && hue <= 95 && saturation >= 0.5 && value >= 0.6) return PixelClass.LIME
        if (hue >= 10 && hue <= 35 && saturation >= 0.6 && value >= 0.55) return PixelClass.ORANGE
        return PixelClass.OTHER
    }

    /** Decision from the measured shares. */
    fun classify(sample: PersonRoleSample): PersonRole {
        if (sample.torsoPixels < minTorsoPixels) return PersonRole.PEDESTRIAN
        val lime = sample.limeShare; val orange = sample.orangeShare
        if (max(lime, orange) < minVestShare) return PersonRole.PEDESTRIAN
        if (lime >= orange) {
            return if (sample.darkShare >= minDarkShare) PersonRole.TRAFFIC_OFFICER else PersonRole.ROAD_WORKER
        }
        return PersonRole.ROAD_WORKER
    }

    /** Measures the shares from the pixels of the torso band and of the whole box. */
    fun sample(torso: List<RGBPixel>, box: List<RGBPixel>): PersonRoleSample {
        var lime = 0; var orange = 0; var dark = 0
        for (p in torso) {
            when (pixelClass(p)) {
                PixelClass.LIME -> lime++
                PixelClass.ORANGE -> orange++
                else -> {}
            }
        }
        for (p in box) if (pixelClass(p) == PixelClass.DARK) dark++
        val t = max(1, torso.size).toDouble(); val b = max(1, box.size).toDouble()
        return PersonRoleSample(lime / t, orange / t, if (box.isEmpty()) 0.0 else dark / b, torso.size)
    }

    fun classify(torso: List<RGBPixel>, box: List<RGBPixel>): PersonRole = classify(sample(torso, box))

    /**
     * Samples a 4-byte-per-pixel buffer (BGRA by default, RGBA with [bgra] = false) inside the person box given in
     * pixels. Returns null when the box is too small to judge.
     */
    fun sampleBGRA(
        base: ByteArray, width: Int, height: Int, bytesPerRow: Int,
        rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
        step: Int = 2, bgra: Boolean = true,
    ): PersonRoleSample? {
        val x0 = max(0, min(width - 1, rectX))
        val y0 = max(0, min(height - 1, rectY))
        val x1 = max(x0, min(width, rectX + rectWidth))
        val y1 = max(y0, min(height, rectY + rectHeight))
        if (!(x1 > x0 && y1 > y0 && bytesPerRow >= width * 4 && rectHeight >= minBoxHeightPixels)) return null
        val s = max(1, step)
        val torsoY0 = rectY + (rectHeight * torsoTop).toInt()
        val torsoY1 = rectY + (rectHeight * torsoBottom).toInt()
        val margin = rectWidth * (1 - torsoWidth) / 2
        val torsoX0 = rectX + margin.toInt()
        val torsoX1 = rectX + rectWidth - margin.toInt()
        var lime = 0; var orange = 0; var dark = 0; var torsoCount = 0; var total = 0
        var y = y0
        while (y < y1) {
            val row = y * bytesPerRow
            val inTorsoRow = y >= torsoY0 && y < torsoY1
            var x = x0
            while (x < x1) {
                val cls = pixelClass(pixelAt(base, row + x * 4, bgra))
                if (cls == PixelClass.DARK) dark++
                total++
                if (inTorsoRow && x >= torsoX0 && x < torsoX1) {
                    torsoCount++
                    if (cls == PixelClass.LIME) lime++ else if (cls == PixelClass.ORANGE) orange++
                }
                x += s
            }
            y += s
        }
        if (total <= 0) return null
        val t = max(1, torsoCount).toDouble()
        return PersonRoleSample(lime / t, orange / t, dark.toDouble() / total, torsoCount)
    }

    fun classifyBGRA(
        base: ByteArray, width: Int, height: Int, bytesPerRow: Int,
        rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
        step: Int = 2, bgra: Boolean = true,
    ): PersonRole? = sampleBGRA(base, width, height, bytesPerRow, rectX, rectY, rectWidth, rectHeight, step, bgra)
        ?.let { classify(it) }

    // Voting

    /** Observations kept per track. */
    const val voteWindow = 9
    /** Observations needed before a role is reported. */
    const val minVotes = 5

    /**
     * Role of a track from its recent per-frame observations: [previous] with fewer than [minObservations]; a role
     * with a strict majority wins; without one the previous role is kept (no flicker), or PEDESTRIAN when none.
     */
    fun majority(history: List<PersonRole>, previous: PersonRole? = null, minObservations: Int = minVotes): PersonRole? {
        if (history.size < max(1, minObservations)) return previous
        val counts = LinkedHashMap<PersonRole, Int>()
        for (role in history) counts[role] = (counts[role] ?: 0) + 1
        val best = counts.entries.maxByOrNull { it.value }
        if (best != null && best.value * 2 > history.size) return best.key
        return previous ?: PersonRole.PEDESTRIAN
    }
}
