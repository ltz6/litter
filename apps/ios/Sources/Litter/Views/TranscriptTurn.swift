import Foundation

struct TranscriptTurn: Identifiable, Equatable {
    struct Preview: Equatable {
        let primaryText: String
        let secondaryText: String?
        let durationText: String?
        let imageCount: Int
        let toolCallCount: Int
        let eventCount: Int
        let widgetCount: Int
    }

    let id: String
    let messages: [ChatMessage]
    let preview: Preview
    let isLive: Bool
    let isCollapsedByDefault: Bool
    let renderDigest: Int

    static func build(
        from messages: [ChatMessage],
        threadStatus: ConversationStatus,
        expandedRecentTurnCount: Int = 3
    ) -> [TranscriptTurn] {
        let groupedMessages = group(messages)
        guard !groupedMessages.isEmpty else { return [] }
        let isStreaming: Bool
        if case .thinking = threadStatus {
            isStreaming = true
        } else {
            isStreaming = false
        }

        let lastIndex = groupedMessages.index(before: groupedMessages.endIndex)
        let collapseBoundary = max(0, groupedMessages.count - expandedRecentTurnCount)

        return groupedMessages.enumerated().map { index, turnMessages in
            let isLive = isStreaming && index == lastIndex
            return TranscriptTurn(
                id: turnIdentifier(for: turnMessages, ordinal: index),
                messages: turnMessages,
                preview: makePreview(from: turnMessages),
                isLive: isLive,
                isCollapsedByDefault: index < collapseBoundary,
                renderDigest: makeRenderDigest(from: turnMessages, isLive: isLive)
            )
        }
    }

    func withCollapsedByDefault(_ isCollapsedByDefault: Bool) -> TranscriptTurn {
        TranscriptTurn(
            id: id,
            messages: messages,
            preview: preview,
            isLive: isLive,
            isCollapsedByDefault: isCollapsedByDefault,
            renderDigest: renderDigest
        )
    }

    private static func group(_ messages: [ChatMessage]) -> [[ChatMessage]] {
        var groups: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        var currentSourceTurnId: String?

        for message in messages {
            let startsNewTurn =
                !current.isEmpty &&
                (
                    message.isFromUserTurnBoundary ||
                    (
                        message.sourceTurnId != nil &&
                        message.sourceTurnId != currentSourceTurnId
                    )
                )

            if startsNewTurn {
                groups.append(current)
                current = [message]
            } else {
                current.append(message)
            }

            currentSourceTurnId = current.first?.sourceTurnId
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups
    }

    private static func turnIdentifier(for messages: [ChatMessage], ordinal: Int) -> String {
        if let first = messages.first {
            if let sourceTurnId = messages.first(where: { $0.sourceTurnId != nil })?.sourceTurnId {
                return "turn-\(sourceTurnId)-\(first.id.uuidString)"
            }
            return "turn-\(first.id.uuidString)"
        }
        return "turn-\(ordinal)"
    }

    private static func makeRenderDigest(from messages: [ChatMessage], isLive: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(messages.count)
        hasher.combine(isLive)
        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.renderDigest)
        }
        return hasher.finalize()
    }

    private static func makePreview(from messages: [ChatMessage]) -> Preview {
        let primaryMessage = messages.first(where: { $0.role == .user }) ?? messages.first
        let secondaryMessage =
            messages.first {
                guard let primaryMessage else { return true }
                return $0.id != primaryMessage.id && $0.role == .assistant
            } ??
            messages.first {
                guard let primaryMessage else { return true }
                return $0.id != primaryMessage.id && $0.role == .system
            }

        return Preview(
            primaryText: previewText(for: primaryMessage),
            secondaryText: secondaryMessage.map(previewText(for:)),
            durationText: formattedDuration(for: messages),
            imageCount: messages.reduce(0) { $0 + $1.images.count },
            toolCallCount: toolCallCount(in: messages),
            eventCount: eventCount(in: messages),
            widgetCount: messages.filter { $0.widgetState != nil }.count
        )
    }

    private static func previewText(for message: ChatMessage?) -> String {
        guard let message else { return "Conversation turn" }

        if let widget = message.widgetState {
            return "Widget: \(widget.title)"
        }

        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if message.role == .system,
               trimmed.hasPrefix("### "),
               let title = systemTitle(from: trimmed) {
                let body = systemBody(from: trimmed)
                return body.isEmpty ? title : "\(title): \(body)"
            }
            return collapsedExcerpt(from: trimmed)
        }

        if !message.images.isEmpty {
            return message.images.count == 1 ? "Shared 1 image" : "Shared \(message.images.count) images"
        }

        return message.role == .assistant ? "Assistant response" : "Conversation turn"
    }

    private static func formattedDuration(for messages: [ChatMessage]) -> String? {
        let userTimestamp =
            messages.first(where: { $0.role == .user && $0.isFromUserTurnBoundary })?.timestamp ??
            messages.first(where: { $0.role == .user })?.timestamp
        let assistantTimestamp = messages.last(where: { $0.role == .assistant })?.timestamp

        if let userTimestamp,
           let assistantTimestamp {
            let interval = max(0, assistantTimestamp.timeIntervalSince(userTimestamp))
            if interval >= 0.05 {
                return formatDuration(seconds: interval)
            }
        }

        if let explicitMillis = explicitDurationMillis(in: messages) {
            return formatDuration(milliseconds: explicitMillis)
        }

        return nil
    }

    private static func explicitDurationMillis(in messages: [ChatMessage]) -> Int? {
        let pattern = #"(?im)^duration:\s*([0-9]+)\s*ms\b"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let total = messages.reduce(into: 0) { runningTotal, message in
            guard message.role == .system,
                  let regex,
                  let match = regex.firstMatch(
                    in: message.text,
                    options: [],
                    range: NSRange(message.text.startIndex..., in: message.text)
                  ),
                  let range = Range(match.range(at: 1), in: message.text),
                  let millis = Int(message.text[range]) else {
                return
            }
            runningTotal += millis
        }

        return total > 0 ? total : nil
    }

    private static func formatDuration(milliseconds: Int) -> String {
        if milliseconds < 1000 {
            return "\(milliseconds)ms"
        }
        return formatDuration(seconds: Double(milliseconds) / 1000)
    }

    private static func formatDuration(seconds interval: TimeInterval) -> String {
        if interval < 1 {
            return "\(Int((interval * 1000).rounded()))ms"
        }

        if interval < 10 {
            let roundedTenths = (interval * 10).rounded() / 10
            if roundedTenths.rounded() == roundedTenths {
                return "\(Int(roundedTenths))s"
            }
            return "\(roundedTenths.formatted(.number.precision(.fractionLength(1))))s"
        }

        if interval < 60 {
            return "\(Int(interval.rounded()))s"
        }

        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if totalSeconds < 3600 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }

        let hours = totalSeconds / 3600
        let remainingMinutes = (totalSeconds % 3600) / 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    private static func toolCallCount(in messages: [ChatMessage]) -> Int {
        messages.reduce(into: 0) { count, message in
            guard message.role == .system,
                  let title = systemTitle(from: message.text),
                  ToolCallKind.from(title: title) != nil else {
                return
            }
            count += 1
        }
    }

    private static func eventCount(in messages: [ChatMessage]) -> Int {
        messages.reduce(into: 0) { count, message in
            guard message.role == .system,
                  message.widgetState == nil else {
                return
            }

            if let title = systemTitle(from: message.text),
               ToolCallKind.from(title: title) != nil {
                return
            }

            count += 1
        }
    }

    private static func collapsedExcerpt(from text: String) -> String {
        let normalized = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "```" }
            .joined(separator: " ")

        if normalized.count <= 180 {
            return normalized
        }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: 180)
        return String(normalized[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func systemTitle(from text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return nil }
        let title = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title)
    }

    private static func systemBody(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return "" }
        let body = lines.dropFirst().joined(separator: "\n")
        return collapsedExcerpt(from: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
