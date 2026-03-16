import Foundation

struct VoiceSessionDebugEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let line: String

    init(id: UUID = UUID(), timestamp: Date = Date(), line: String) {
        self.id = id
        self.timestamp = timestamp
        self.line = line
    }
}

enum VoiceSessionPhase: String, Equatable {
    case connecting
    case listening
    case thinking
    case speaking
    case error

    var displayTitle: String {
        switch self {
        case .connecting:
            return "Connecting"
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Codex Speaking"
        case .error:
            return "Call Ended"
        }
    }

    var activityPhase: CodexVoiceCallAttributes.ContentState.Phase {
        switch self {
        case .connecting: .connecting
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .error: .error
        }
    }
}

enum VoiceSessionAudioRoute: Equatable {
    case speaker
    case receiver
    case headphones(String)
    case bluetooth(String)
    case airPlay(String)
    case unknown(String)

    var label: String {
        switch self {
        case .speaker:
            return "Speaker"
        case .receiver:
            return "iPhone"
        case .headphones(let name), .bluetooth(let name), .airPlay(let name), .unknown(let name):
            return name
        }
    }

    var supportsSpeakerToggle: Bool {
        switch self {
        case .speaker, .receiver, .unknown:
            return true
        case .headphones, .bluetooth, .airPlay:
            return false
        }
    }
}

struct VoiceSessionState: Identifiable, Equatable {
    let threadKey: ThreadKey
    let threadTitle: String
    let model: String
    let startedAt: Date
    var sessionId: String?
    var phase: VoiceSessionPhase
    var lastError: String?
    var route: VoiceSessionAudioRoute
    var transcriptText: String?
    var transcriptSpeaker: String?
    var inputLevel: Float
    var outputLevel: Float
    var isListening: Bool
    var isSpeaking: Bool
    var debugEntries: [VoiceSessionDebugEntry]

    var id: String {
        "\(threadKey.serverId):\(threadKey.threadId)"
    }

    var statusText: String {
        if let error = lastError, !error.isEmpty {
            return error
        }
        if let transcriptText,
           !transcriptText.isEmpty,
           let transcriptSpeaker,
           !transcriptSpeaker.isEmpty {
            return "\(transcriptSpeaker): \(transcriptText)"
        }
        return phase.displayTitle
    }

    var activityContentState: CodexVoiceCallAttributes.ContentState {
        CodexVoiceCallAttributes.ContentState(
            phase: phase.activityPhase,
            routeLabel: route.label,
            transcriptText: transcriptText,
            lastError: lastError
        )
    }

    static func initial(threadKey: ThreadKey, threadTitle: String, model: String) -> VoiceSessionState {
        VoiceSessionState(
            threadKey: threadKey,
            threadTitle: threadTitle.isEmpty ? "Voice Session" : threadTitle,
            model: model.isEmpty ? "Codex" : model,
            startedAt: Date(),
            sessionId: nil,
            phase: .connecting,
            lastError: nil,
            route: .speaker,
            transcriptText: nil,
            transcriptSpeaker: nil,
            inputLevel: 0,
            outputLevel: 0,
            isListening: false,
            isSpeaking: false,
            debugEntries: []
        )
    }
}
