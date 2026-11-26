package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min

// On-device HEURISTIC distinction of a traffic police officer (YHXX xodimi) and a road worker (yo‘l ishchisi) among the
// detector's "person" boxes, from the colour of the high-visibility vest on the torso:
//  - fluorescent yellow-green / lime vest (hue 55–100°, S ≥ 0.30, V ≥ 0.40) over a dark / navy lower body and without
//    orange → traffic officer (officer vs worker stays a guess);
//  - fluorescent orange / red-orange vest (hue 3–38°, S ≥ 0.70, V ≥ 0.50) → road worker
//    (a lime vest without a dark lower body is also treated as a road worker);
//  - otherwise → pedestrian.
// The gates mirror the Swift core, where they were measured on person crops of a construction-safety dataset (not road
// scenes; see PersonRoleClassifier.swift). Nothing was measured on the Kotlin side.
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
    /**
     * Dark or navy pixels / sampled pixels of the lower body (rows 62–95 % of the box); null when not measured (then
     * the whole-box [darkShare] decides officer vs worker, as before).
     */
    val lowerDarkShare: Double? = null,
)

object PersonRoleClassifier {
    /** Torso band of the box: rows from 22 % to 62 % of the box height… */
    const val torsoTop = 0.22
    const val torsoBottom = 0.62
    /** …and the central 60 % of its width. */
    const val torsoWidth = 0.6
    /** Minimum vest share of the torso pixels (0.12 before; raised together with the wider colour gates). */
    const val minVestShare = 0.15
    /** Lower body band: rows from 62 % to 95 % of the box height. */
    const val lowerBodyBottom = 0.95
    /** Officer: at least this share of the lower body is dark / navy (uniform trousers)… */
    const val minLowerDarkShare = 0.5
    /** …and (almost) no orange on the torso. */
    const val maxOfficerOrangeShare = 0.05
    /** Hi-vis colour gates (hue in degrees). */
    internal const val limeHueMin = 55.0
    internal const val limeHueMax = 100.0
    internal const val limeMinSaturation = 0.30
    internal const val limeMinValue = 0.40
    internal const val orangeHueMin = 3.0
    internal const val orangeHueMax = 38.0
    internal const val orangeMinSaturation = 0.70
    internal const val orangeMinValue = 0.50
    /** Navy (uniform) pixel: hue 200–260° and V below this (brighter blue is ordinary clothing). */
    internal const val navyHueMin = 200.0
    internal const val navyHueMax = 260.0
    internal const val navyMaxValue = 0.45
    /** Minimum share of dark pixels in the box for an officer (dark uniform). */
    const val minDarkShare = 0.08
    /** Minimum number of sampled torso pixels for a decision. */
    const val minTorsoPixels = 12
    /** Boxes smaller than this (pixels of height) are not classified. */
    const val minBoxHeightPixels = 40

    internal enum class PixelClass { LIME, ORANGE, DARK, NAVY, OTHER }

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
        if (hue >= limeHueMin && hue <= limeHueMax && saturation >= limeMinSaturation && value >= limeMinValue) return PixelClass.LIME
        if (hue >= orangeHueMin && hue <= orangeHueMax && saturation >= orangeMinSaturation && value >= orangeMinValue) return PixelClass.ORANGE
        if (hue >= navyHueMin && hue <= navyHueMax && value < navyMaxValue) return PixelClass.NAVY
        return PixelClass.OTHER
    }

    /** Decision from the measured shares. */
    fun classify(sample: PersonRoleSample): PersonRole {
        if (sample.torsoPixels < minTorsoPixels) return PersonRole.PEDESTRIAN
        val lime = sample.limeShare; val orange = sample.orangeShare
        if (max(lime, orange) < minVestShare) return PersonRole.PEDESTRIAN
        if (lime >= orange) {
            val lower = sample.lowerDarkShare
            if (lower != null) {
                // Structure rule: lime top over dark / navy trousers and no orange → officer; else worker.
                return if (lower >= minLowerDarkShare && orange < maxOfficerOrangeShare) PersonRole.TRAFFIC_OFFICER
                else PersonRole.ROAD_WORKER
            }
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
        val lowerY1 = rectY + (rectHeight * lowerBodyBottom).toInt()
        var lime = 0; var orange = 0; var dark = 0; var torsoCount = 0; var total = 0
        var lowerCount = 0; var lowerDark = 0
        var y = y0
        while (y < y1) {
            val row = y * bytesPerRow
            val inTorsoRow = y >= torsoY0 && y < torsoY1
            val inLowerRow = y >= torsoY1 && y < lowerY1
            var x = x0
            while (x < x1) {
                val cls = pixelClass(pixelAt(base, row + x * 4, bgra))
                if (cls == PixelClass.DARK) dark++
                total++
                if (inTorsoRow && x >= torsoX0 && x < torsoX1) {
                    torsoCount++
                    if (cls == PixelClass.LIME) lime++ else if (cls == PixelClass.ORANGE) orange++
                }
                if (inLowerRow && x >= torsoX0 && x < torsoX1) {
                    lowerCount++
                    if (cls == PixelClass.DARK || cls == PixelClass.NAVY) lowerDark++
                }
                x += s
            }
            y += s
        }
        if (total <= 0) return null
        val t = max(1, torsoCount).toDouble()
        return PersonRoleSample(lime / t, orange / t, dark.toDouble() / total, torsoCount,
            if (lowerCount > 0) lowerDark.toDouble() / lowerCount else null)
    }

    fun classifyBGRA(
        base: ByteArray, width: Int, height: Int, bytesPerRow: Int,
        rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
        step: Int = 2, bgra: Boolean = true,
    ): PersonRole? = sampleBGRA(base, width, height, bytesPerRow, rectX, rectY, rectWidth, rectHeight, step, bgra)
        ?.let { classify(it) }

    // Voting

    /** Observations kept per track (≈ 1 s at 15 fps; 9 with a strict majority before). */
    const val voteWindow = 15
    /** Observations needed before a role is reported. */
    const val minVotes = 5
    /** Staff (officer + worker together) is reported from this share of the window… */
    const val staffEnterShare = 0.6
    /** …and kept until its share drops below this (hysteresis, no flicker). Reasoning, not measured on video. */
    const val staffKeepShare = 0.3

    /**
     * Role of a track from its recent per-frame observations: [previous] with fewer than [minObservations].
     * Officer and worker votes are pooled ("wears hi-vis"): staff is entered at [staffEnterShare] and kept down to
     * [staffKeepShare]; the more frequent of the two names the role (ties keep the previous one).
     */
    fun majority(history: List<PersonRole>, previous: PersonRole? = null, minObservations: Int = minVotes): PersonRole? {
        if (history.size < max(1, minObservations)) return previous
        var officer = 0; var worker = 0
        for (role in history) {
            if (role == PersonRole.TRAFFIC_OFFICER) officer++ else if (role == PersonRole.ROAD_WORKER) worker++
        }
        val share = (officer + worker).toDouble() / history.size.toDouble()
        val wasStaff = previous?.isRoadStaff == true
        if (share < (if (wasStaff) staffKeepShare else staffEnterShare)) return PersonRole.PEDESTRIAN
        if (officer == worker && previous != null && previous.isRoadStaff) return previous
        return if (officer >= worker) PersonRole.TRAFFIC_OFFICER else PersonRole.ROAD_WORKER
    }
}
