import Foundation
import OSLog
import UIKit

enum LLog {
    private static let subsystemRoot = Bundle.main.bundleIdentifier ?? "com.sigkitten.litter"
    private static let logs = Logs()
    private static let queue = DispatchQueue(label: "com.sigkitten.litter.logging", qos: .utility)
    private nonisolated(unsafe) static var bootstrapped = false

    static func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let codexHome = resolveCodexHome()
        FileManager.default.createFile(atPath: codexHome.path, contents: nil)
        setenv("CODEX_HOME", codexHome.path, 1)

        let configPath = codexHome
            .appendingPathComponent("log-spool", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: configPath.path) {
            return
        }

        logs.configure(
            config: LogConfig(
                enabled: false,
                collectorUrl: nil,
                bearerToken: nil,
                minLevel: .info,
                deviceId: UIDevice.current.identifierForVendor?.uuidString,
                deviceName: UIDevice.current.name,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            )
        )
    }

    static func trace(_ subsystem: String, _ message: String, fields: [String: Any] = [:], payloadJson: String? = nil) {
        emit(level: .trace, subsystem: subsystem, message: message, fields: fields, payloadJson: payloadJson)
    }

    static func debug(_ subsystem: String, _ message: String, fields: [String: Any] = [:], payloadJson: String? = nil) {
        emit(level: .debug, subsystem: subsystem, message: message, fields: fields, payloadJson: payloadJson)
    }

    static func info(_ subsystem: String, _ message: String, fields: [String: Any] = [:], payloadJson: String? = nil) {
        emit(level: .info, subsystem: subsystem, message: message, fields: fields, payloadJson: payloadJson)
    }

    static func warn(_ subsystem: String, _ message: String, fields: [String: Any] = [:], payloadJson: String? = nil) {
        emit(level: .warn, subsystem: subsystem, message: message, fields: fields, payloadJson: payloadJson)
    }

    static func error(_ subsystem: String, _ message: String, error: Error? = nil, fields: [String: Any] = [:], payloadJson: String? = nil) {
        var allFields = fields
        if let error {
            allFields["error"] = error.localizedDescription
        }
        emit(level: .error, subsystem: subsystem, message: message, fields: allFields, payloadJson: payloadJson)
    }

    private static func emit(level: LogLevel, subsystem: String, message: String, fields: [String: Any], payloadJson: String?) {
        let logger = Logger(subsystem: subsystemRoot, category: subsystem)
        switch level {
        case .trace, .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warn:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }

        queue.async {
            logs.log(
                event: LogEvent(
                    timestampMs: nil,
                    level: level,
                    source: .ios,
                    subsystem: subsystem,
                    category: subsystem,
                    message: message,
                    sessionId: nil,
                    serverId: nil,
                    threadId: nil,
                    requestId: nil,
                    payloadJson: payloadJson,
                    fieldsJson: jsonString(from: fields)
                )
            )
        }
    }

    private static func resolveCodexHome() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let codexHome = base.appendingPathComponent("codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        return codexHome
    }

    private static func jsonString(from fields: [String: Any]) -> String? {
        guard !fields.isEmpty, JSONSerialization.isValidJSONObject(fields) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
