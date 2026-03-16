import CoreFoundation
import Foundation

enum VoiceSessionControl {
    static let realtimeFeatureName = "realtime_conversation"
    static let defaultPrompt = "You are Codex in a live voice conversation inside Litter. Keep responses short, spoken, and conversational. Avoid markdown and code formatting unless explicitly asked."

    private static let appGroupSuite = LitterPalette.appGroupSuite
    private static let endRequestKey = "voice_session.end_request_token"
    static let endRequestDarwinNotification = "com.sigkitten.litter.voice_session.end_request"

    static func requestEnd() {
        let token = UUID().uuidString
        UserDefaults(suiteName: appGroupSuite)?.set(token, forKey: endRequestKey)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(endRequestDarwinNotification as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }

    static func pendingEndRequestToken(after lastSeenToken: String?) -> String? {
        guard let token = UserDefaults(suiteName: appGroupSuite)?.string(forKey: endRequestKey),
              !token.isEmpty,
              token != lastSeenToken else {
            return nil
        }
        return token
    }
}
