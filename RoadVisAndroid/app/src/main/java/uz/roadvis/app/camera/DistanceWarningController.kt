package uz.roadvis.app.camera

import uz.roadvis.app.app.SpeechPriority
import uz.roadvis.app.app.SpeechService
import uz.roadvis.app.l10n.L
import uz.roadvis.core.AlertToneKind
import uz.roadvis.core.DistanceStatus
import uz.roadvis.core.FollowingDistanceAssessment
import uz.roadvis.core.FollowingDistancePolicy
import uz.roadvis.core.VoicePhrase

/** Haptic feedback kinds requested by the warning controller and the coach (performed by the camera view). */
enum class AssistHaptic { ERROR, WARNING, LIGHT, SOFT }

/**
 * Haptic / tone / voice warnings for the gap to the lead vehicle (port of iOS `DistanceWarningController`, fed once
 * per processed frame on the main thread).
 * - Moving + danger with a time to collision below `policy.collisionWarningSeconds` (held ≥ 0.2 s) → error haptic,
 *   collision alert tone, voice "collision" (critical priority — interrupts everything, ≤ every 5 s).
 * - Moving + danger without such a TTC (too close, held ≥ 1 s) → light haptic, voice "keep distance" (≤ every 12 s);
 *   in the "sounds only" mode a short tone instead.
 * Tones follow the sound mode (`AlertToneKind.shouldPlay`, checked by `SpeechService.playAlertTone`); haptics do not.
 * - Standing: never a sound or voice — one soft haptic when the gap drops below the stopped gap.
 * Voice is given only when [speech] is set; the driver coach takes over the spoken warnings (as on iOS) and sets it
 * to null, so nothing is said twice.
 */
class DistanceWarningController {
    var speech: SpeechService? = null
    /** Plays an alert tone when the sound mode allows it (`SpeechService.playAlertTone`); stays set when the coach speaks. */
    var tones: ((AlertToneKind) -> Boolean)? = null
    var haptic: ((AssistHaptic) -> Unit)? = null

    private var lastCollisionAlert: Double? = null
    private var lastKeepDistanceAlert: Double? = null
    private var collisionSince: Double? = null
    private var tooCloseSince: Double? = null
    private var stoppedHapticFired = false
    private var stoppedEpisodeLeadID: Int? = null

    fun evaluate(assessment: FollowingDistanceAssessment?, leadID: Int?, policy: FollowingDistancePolicy,
                 enabled: Boolean, now: Double = RecognitionWorker.uptimeSeconds()) {
        val distance = assessment?.distanceMeters
        if (!enabled || assessment == null || leadID == null || distance == null || !distance.isFinite()) {
            collisionSince = null
            tooCloseSince = null
            return
        }
        if (assessment.isStopped) {
            collisionSince = null
            tooCloseSince = null
            if (stoppedEpisodeLeadID != leadID) {
                stoppedEpisodeLeadID = leadID
                stoppedHapticFired = false
            }
            if (distance < policy.stoppedGapMeters) {
                if (!stoppedHapticFired) {
                    stoppedHapticFired = true
                    haptic?.invoke(AssistHaptic.SOFT)
                }
            } else if (distance > policy.stoppedGapMeters * 1.3 + 0.3) {
                stoppedHapticFired = false   // re-arm once the gap clearly opened again
            }
            return
        }
        stoppedHapticFired = false
        stoppedEpisodeLeadID = null

        if (isForwardCollision(assessment, policy)) {
            tooCloseSince = null
            val since = collisionSince ?: now
            collisionSince = since
            if (now - since < COLLISION_PERSISTENCE) return
            lastCollisionAlert?.let { if (now - it < COLLISION_REPEAT) return }
            lastCollisionAlert = now
            lastKeepDistanceAlert = now   // no "keep distance" right after the collision warning
            haptic?.invoke(AssistHaptic.ERROR)
            tones?.invoke(AlertToneKind.COLLISION)
            speech?.speak(VoicePhrase.fixed("collision_alert", L("voice.collision")), SpeechPriority.CRITICAL)
        } else if (isTooClose(assessment, policy)) {
            collisionSince = null
            val since = tooCloseSince ?: now
            tooCloseSince = since
            if (now - since < TOO_CLOSE_PERSISTENCE) return
            lastKeepDistanceAlert?.let { if (now - it < KEEP_DISTANCE_REPEAT) return }
            lastKeepDistanceAlert = now
            haptic?.invoke(AssistHaptic.LIGHT)
            tones?.invoke(AlertToneKind.ATTENTION)
            speech?.speak(VoicePhrase.fixed("keep_distance", L("voice.keepDistance")), SpeechPriority.NORMAL, maxAge = 3.0)
        } else {
            collisionSince = null
            tooCloseSince = null
        }
    }

    /** Forgets the persistence timers and the standing episode; the repeat throttles are kept. */
    fun reset() {
        collisionSince = null
        tooCloseSince = null
        stoppedHapticFired = false
        stoppedEpisodeLeadID = null
    }

    companion object {
        const val COLLISION_REPEAT = 5.0
        const val KEEP_DISTANCE_REPEAT = 12.0
        const val COLLISION_PERSISTENCE = 0.2
        const val TOO_CLOSE_PERSISTENCE = 1.0

        /** Moving, dangerously close and closing faster than the collision-warning threshold. */
        fun isForwardCollision(a: FollowingDistanceAssessment, policy: FollowingDistancePolicy): Boolean {
            if (a.isStopped || a.status != DistanceStatus.DANGER) return false
            val ttc = a.timeToCollisionSeconds ?: return false
            return ttc.isFinite() && ttc < policy.collisionWarningSeconds
        }

        fun isTooClose(a: FollowingDistanceAssessment, policy: FollowingDistancePolicy): Boolean =
            !a.isStopped && a.status == DistanceStatus.DANGER && !isForwardCollision(a, policy)
    }
}
