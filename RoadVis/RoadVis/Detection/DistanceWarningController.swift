import Foundation
import UIKit
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Haptic / sound / voice warnings for the gap to the lead vehicle (owned by `RecognitionPipeline`, fed once per
/// processed frame).
///
/// Rules
/// - Moving + `.danger` with a time to collision below `policy.collisionWarningSeconds` (held ≥ 0.2 s) →
///   forward-collision warning: error haptic, short system alert tone, voice "Внимание! Опасное сближение"
///   (high priority, at most every 5 s).
/// - Moving + `.danger` without such a TTC (simply too close, held ≥ 1 s) → light haptic and voice
///   "Держите дистанцию" (normal priority, at most every 12 s).
/// - Standing: never a sound or voice — only one soft haptic when the gap drops below the stopped gap
///   (re-armed after the gap opens again or another vehicle becomes the lead).
///
/// Distances are monocular estimates, so warnings are throttled and require the condition to persist.
@MainActor
final class DistanceWarningController {
    /// Voice output (set by the pipeline from `AppState`); nil → haptics and tone only.
    weak var speech: SpeechService?

    static var collisionPhrase: String { L("voice.collision") }
    static var keepDistancePhrase: String { L("voice.keepDistance") }
    /// Minimum time between two forward-collision warnings, seconds.
    static let collisionRepeatInterval: TimeInterval = 5
    /// Minimum time between two "keep distance" reminders, seconds.
    static let keepDistanceRepeatInterval: TimeInterval = 12
    /// How long the collision condition must hold before warning, seconds.
    static let collisionPersistence: TimeInterval = 0.2
    /// How long "too close" must hold before reminding, seconds.
    static let tooClosePersistence: TimeInterval = 1.0
    /// Standard short system alert tone.
    static let alertSoundID: UInt32 = 1005

    private var lastCollisionAlert: Date?
    private var lastKeepDistanceAlert: Date?
    private var collisionSince: Date?
    private var tooCloseSince: Date?
    private var stoppedHapticFired = false
    private var stoppedEpisodeLeadID: Int?

    private lazy var notificationFeedback = UINotificationFeedbackGenerator()
    private lazy var lightImpact = UIImpactFeedbackGenerator(style: .light)
    private lazy var softImpact = UIImpactFeedbackGenerator(style: .soft)

    init(speech: SpeechService? = nil) {
        self.speech = speech
    }

    /// Moving, dangerously close and closing faster than the collision-warning threshold.
    static func isForwardCollision(_ assessment: FollowingDistanceAssessment, policy: FollowingDistancePolicy) -> Bool {
        guard !assessment.isStopped, assessment.status == .danger,
              let ttc = assessment.timeToCollisionSeconds, ttc.isFinite else { return false }
        return ttc < policy.collisionWarningSeconds
    }

    /// Moving and dangerously close (less than half the recommended gap) without an imminent collision.
    static func isTooClose(_ assessment: FollowingDistanceAssessment, policy: FollowingDistancePolicy) -> Bool {
        !assessment.isStopped && assessment.status == .danger && !isForwardCollision(assessment, policy: policy)
    }

    /// Feeds one assessment (call once per processed frame).
    /// - Parameters:
    ///   - leadID: track id of the lead vehicle (nil = no lead → nothing to warn about).
    ///   - enabled: `settings.distanceWarningsEnabled`.
    func evaluate(_ assessment: FollowingDistanceAssessment?, leadID: Int?, policy: FollowingDistancePolicy,
                  enabled: Bool, now: Date = Date()) {
        guard enabled, let assessment, let leadID, let distance = assessment.distanceMeters, distance.isFinite else {
            collisionSince = nil
            tooCloseSince = nil
            return
        }

        if assessment.isStopped {
            collisionSince = nil
            tooCloseSince = nil
            if stoppedEpisodeLeadID != leadID {
                stoppedEpisodeLeadID = leadID
                stoppedHapticFired = false
            }
            if distance < policy.stoppedGapMeters {
                if !stoppedHapticFired {
                    stoppedHapticFired = true
                    softImpact.impactOccurred(intensity: 0.7)
                }
            } else if distance > policy.stoppedGapMeters * 1.3 + 0.3 {
                stoppedHapticFired = false   // re-arm once the gap clearly opened again
            }
            return
        }
        stoppedHapticFired = false
        stoppedEpisodeLeadID = nil

        if Self.isForwardCollision(assessment, policy: policy) {
            tooCloseSince = nil
            let since = collisionSince ?? now
            collisionSince = since
            guard now.timeIntervalSince(since) >= Self.collisionPersistence else { return }
            if let last = lastCollisionAlert, now.timeIntervalSince(last) < Self.collisionRepeatInterval { return }
            lastCollisionAlert = now
            lastKeepDistanceAlert = now   // no "keep distance" right after the collision warning
            notificationFeedback.notificationOccurred(.error)
            playAlertTone()
            speech?.speak(Self.collisionPhrase, priority: .high)
        } else if Self.isTooClose(assessment, policy: policy) {
            collisionSince = nil
            let since = tooCloseSince ?? now
            tooCloseSince = since
            guard now.timeIntervalSince(since) >= Self.tooClosePersistence else { return }
            if let last = lastKeepDistanceAlert, now.timeIntervalSince(last) < Self.keepDistanceRepeatInterval { return }
            lastKeepDistanceAlert = now
            lightImpact.impactOccurred()
            speech?.speak(Self.keepDistancePhrase, priority: .normal)
        } else {
            collisionSince = nil
            tooCloseSince = nil
        }
    }

    /// Forgets the persistence timers and the standing episode (camera stopped, feature switched off, counters reset).
    /// The repeat throttles are kept so a restart cannot produce a burst of warnings.
    func reset() {
        collisionSince = nil
        tooCloseSince = nil
        stoppedHapticFired = false
        stoppedEpisodeLeadID = nil
    }

    private func playAlertTone() {
        #if canImport(AudioToolbox)
        AudioServicesPlaySystemSound(SystemSoundID(Self.alertSoundID))
        #endif
    }
}
