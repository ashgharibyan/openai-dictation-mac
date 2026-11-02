import Foundation

/// Idle -> Recording -> Transcribing -> Inserting -> Idle, plus cancel and error paths.
/// Success and Error are short-lived display states that accept a new recording immediately.
public enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case inserting
    case success
    case error

    public var isBusy: Bool { self == .recording || self == .transcribing || self == .inserting }
}

public enum DictationEvent: Equatable, Sendable {
    case start
    case stop            // user released / pressed again: hand audio to transcription
    case cancel          // user aborted: discard, back to idle
    case audioUnusable   // too short, silent, or the microphone failed
    case transcribed
    case failed
    case inserted
    case retry           // re-send a kept recording without recording again
    case settle          // success/error display finished
}

public enum DictationStateMachine {
    /// Returns the next phase, or nil when the event is not valid in this phase. Callers ignore
    /// invalid events, which is what prevents overlapping sessions and duplicate requests.
    public static func next(_ phase: DictationPhase, _ event: DictationEvent) -> DictationPhase? {
        switch (phase, event) {
        case (.idle, .start), (.success, .start), (.error, .start): return .recording
        case (.idle, .retry), (.success, .retry), (.error, .retry): return .transcribing
        case (.recording, .stop): return .transcribing
        case (.recording, .cancel), (.transcribing, .cancel): return .idle
        case (.recording, .audioUnusable): return .error
        case (.recording, .failed): return .error
        // Preflight problems (no API key, no microphone access) surface without recording.
        case (.idle, .failed), (.success, .failed), (.error, .failed): return .error
        case (.transcribing, .transcribed): return .inserting
        case (.transcribing, .failed): return .error
        case (.inserting, .inserted): return .success
        case (.inserting, .failed): return .error
        case (.success, .settle), (.error, .settle): return .idle
        case (.success, .cancel), (.error, .cancel): return .idle
        default: return nil
        }
    }
}
