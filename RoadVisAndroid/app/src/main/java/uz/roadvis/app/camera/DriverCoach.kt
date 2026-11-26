package uz.roadvis.app.camera

import uz.roadvis.app.app.AppState
import uz.roadvis.app.app.SpeechPriority
import uz.roadvis.app.app.SpeechService
import uz.roadvis.core.AlertToneKind
import uz.roadvis.core.CoachCategory
import uz.roadvis.core.CoachFrameInput
import uz.roadvis.core.CoachMessage
import uz.roadvis.core.CoachToggles
import uz.roadvis.core.CoachUrgency
import uz.roadvis.core.DriverCoachEngine
import uz.roadvis.core.PedestrianHazard
import uz.roadvis.core.PedestrianHazardLevel
import uz.roadvis.core.RoadStaffSighting
import uz.roadvis.core.SignAnnouncer
import uz.roadvis.core.VoicePhrase

/** Per-frame cues the recognition controller hands to the coach. */
data class DriverAssistFrame(
    val coach: CoachFrameInput,
    /** Confirmed STOP-sign tracks visible on this frame (announced once per track). */
    val confirmedStopSignIDs: List<Int>,
    val pedestrianHazards: List<PedestrianHazard>,
    val roadStaff: List<RoadStaffSighting>,
)

/**
 * Voice coach for beginner drivers (port of iOS `DriverCoach`): following distance, pedestrians on the roadway, traffic
 * police officer / road works ahead, red / green light, lane departure, camera STOP sign and changes of the current
 * road's speed limit (`bus.speedLimitKmh`). [DriverCoachEngine] + `CoachRules` decide when to speak; the phrase is
 * `VoicePhrase.coach(msg)` with [CoachPhrases] as the system-voice text in the app language.
 *
 * Route-feature announcements (OSM signs along the route, speed limit ahead) need the navigator's route data, which the
 * bus does not carry; they are left to the navigation feature. All calls on the main thread.
 */
class DriverCoach(private val app: AppState, private val assist: AssistSettings) {
    private val engine = DriverCoachEngine()
    private val signs = SignAnnouncer()
    private val pedestrianHaptics = HashMap<Int, Double>()
    var haptic: ((AssistHaptic) -> Unit)? = null

    init {
        app.location.addListener { handleLocation() }
    }

    /** Forgets announced signs (e.g. a new trip). */
    fun resetAnnouncements() {
        signs.reset()
        engine.reset()
        pedestrianHaptics.clear()
    }

    fun handle(frame: DriverAssistFrame) {
        val now = RecognitionWorker.uptimeSeconds()
        engine.toggles = currentToggles()
        engine.update(frame.coach.copy(timestamp = now))
        val hazards = if (assist.pedestrianWarningsEnabled) frame.pedestrianHazards else emptyList()
        engine.updatePedestrians(hazards, frame.coach.speedKmh, now)
        engine.updateRoadStaff(if (assist.pedestrianWarningsEnabled) frame.roadStaff else emptyList(), now)
        pedestrianHaptic(hazards, now)
        if (engine.toggles.signs) {
            for (id in frame.confirmedStopSignIDs) {
                signs.cameraStopSign(id, now)?.let { engine.offerSign(it, now) }
            }
        }
        speakNext(now)
    }

    private fun handleLocation() {
        val now = RecognitionWorker.uptimeSeconds()
        engine.toggles = currentToggles()
        if (engine.toggles.signs) {
            signs.update(app.bus.speedLimitKmh, now)?.let { engine.offerSign(it, now) }
        }
        speakNext(now)
    }

    /** Offers a message directly (e.g. over the speed limit). */
    fun offer(message: CoachMessage) {
        val now = RecognitionWorker.uptimeSeconds()
        engine.offer(message, now)
        speakNext(now)
    }

    private fun currentToggles(): CoachToggles {
        val s = app.settings
        val voice = assist.voiceCoachingEnabled
        return CoachToggles(
            distance = s.followingDistanceEnabled && s.distanceWarningsEnabled,
            laneDeparture = voice && assist.laneDepartureEnabled,
            signs = voice && assist.signAnnouncementsEnabled,
            trafficLights = voice && assist.trafficLightHintsEnabled,
            pedestrians = voice && assist.pedestrianWarningsEnabled,
            roadStaff = voice && assist.pedestrianWarningsEnabled,
        )
    }

    /** Warning haptic when a pedestrian danger appears (once per track per 6 s). */
    private fun pedestrianHaptic(hazards: List<PedestrianHazard>, now: Double) {
        pedestrianHaptics.entries.removeAll { now - it.value >= PEDESTRIAN_HAPTIC_COOLDOWN }
        val danger = hazards.firstOrNull { it.level == PedestrianHazardLevel.DANGER } ?: return
        if (pedestrianHaptics.containsKey(danger.trackID)) return
        pedestrianHaptics[danger.trackID] = now
        haptic?.invoke(AssistHaptic.WARNING)
    }

    private fun speakNext(now: Double) {
        // A message without any sound in the current mode (e.g. a sign announcement in "sounds only") must not
        // start the global gap: it would delay the tone of the next warning.
        val mode = app.speech.soundMode
        val message = engine.next(now) { AlertToneKind.isAudible(it, mode) } ?: return
        // Tone first (it is the whole warning in the "sounds only" mode; `playAlertTone` checks the mode). The distance
        // tones (collision, keep distance) belong to `DistanceWarningController`, which runs on the same frames —
        // a second tone here would double up.
        val distanceOwned = message.category == CoachCategory.COLLISION || message.category == CoachCategory.TAILGATING
        if (!distanceOwned) AlertToneKind.kindFor(message)?.let { app.speech.playAlertTone(it) }
        val priority = priority(message.urgency)
        // Only advice about the current moment (lane, distance) is stale after a few seconds of waiting; signs, road
        // staff and pedestrian cautions keep the default wait (a navigation prompt of 4–6 s must not swallow them).
        app.speech.speak(VoicePhrase.coach(message, CoachPhrases.phrase(message)), priority,
            maxAge = message.maxSpeechWait(SpeechService.DEFAULT_MAX_AGE))
    }

    companion object {
        const val PEDESTRIAN_HAPTIC_COOLDOWN = 6.0

        fun priority(u: CoachUrgency): SpeechPriority = when (u) {
            CoachUrgency.LOW -> SpeechPriority.LOW
            CoachUrgency.NORMAL -> SpeechPriority.NORMAL
            CoachUrgency.HIGH -> SpeechPriority.CRITICAL   // collision / pedestrian / red light: never cut off by navigation prompts
        }
    }
}
