import SwiftUI
import MarkdownUI
import Inject

// MARK: - Reusable bubble components

struct UserBubble: View {
    let text: String
    var images: [ChatImage] = []
    var textScale: CGFloat = 1.0
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: compact ? 30 : 60)
            VStack(alignment: .trailing, spacing: compact ? 4 : 8) {
                ForEach(images) { img in
                    if let uiImage = UserBubble.decodeImage(from: img.data, cacheKey: "user-\(img.id.uuidString)") {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .font(LitterFont.styled(compact ? .footnote : .callout, scale: textScale))
                        .foregroundColor(LitterTheme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 6 : 10)
            .modifier(GlassRectModifier(cornerRadius: compact ? 10 : 14, tint: LitterTheme.accent.opacity(0.3)))
        }
    }

    private static let imageCache = NSCache<NSString, UIImage>()

    private static func decodeImage(from data: Data, cacheKey: String) -> UIImage? {
        let key = cacheKey as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }
}

struct AssistantBubble: View, Equatable {
    let markdownContent: MarkdownContent
    let markdownIdentity: Int
    var label: String? = nil
    var textScale: CGFloat = 1.0
    var compact: Bool = false
    @ScaledMetric(relativeTo: .body) private var mdBodySize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var mdCodeSize: CGFloat = 13

    private var bodySize: CGFloat { (compact ? 12 : mdBodySize) * textScale }
    private var codeSize: CGFloat { (compact ? 11 : mdCodeSize) * textScale }

    init(
        text: String,
        label: String? = nil,
        textScale: CGFloat = 1.0,
        compact: Bool = false
    ) {
        self.markdownContent = MarkdownContent(text)
        self.markdownIdentity = text.hashValue
        self.label = label
        self.textScale = textScale
        self.compact = compact
    }

    init(
        markdownContent: MarkdownContent,
        markdownIdentity: Int,
        label: String? = nil,
        textScale: CGFloat = 1.0,
        compact: Bool = false
    ) {
        self.markdownContent = markdownContent
        self.markdownIdentity = markdownIdentity
        self.label = label
        self.textScale = textScale
        self.compact = compact
    }

    static func == (lhs: AssistantBubble, rhs: AssistantBubble) -> Bool {
        lhs.markdownIdentity == rhs.markdownIdentity &&
        lhs.label == rhs.label &&
        lhs.textScale == rhs.textScale &&
        lhs.compact == rhs.compact
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                if let label {
                    Text(label)
                        .font(LitterFont.styled(.caption2, weight: .semibold, scale: textScale))
                        .foregroundColor(LitterTheme.textSecondary)
                }
                Markdown(markdownContent)
                    .markdownTheme(.litter(bodySize: bodySize, codeSize: codeSize))
                    .markdownCodeSyntaxHighlighter(.plain)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: compact ? 8 : 20)
        }
    }
}

struct StreamingAssistantBubble: View {
    let text: String
    var label: String? = nil
    var textScale: CGFloat = 1.0
    var onSnapshotRendered: (() -> Void)? = nil
    @State private var renderedText: String = ""
    @State private var pendingText: String?
    @State private var flushWorkItem: DispatchWorkItem?
    @State private var snapshotOpacity: Double = 1.0

    private let flushInterval: TimeInterval = 0.06

    private var renderedContent: MarkdownContent {
        MarkdownContent(renderedText)
    }

    var body: some View {
        AssistantBubble(
            markdownContent: renderedContent,
            markdownIdentity: renderedText.hashValue,
            label: label,
            textScale: textScale
        )
            .equatable()
            .opacity(snapshotOpacity)
            .onAppear {
                renderedText = text
                onSnapshotRendered?()
            }
            .onChange(of: text) {
                scheduleRenderUpdate(with: text)
            }
            .onDisappear {
                flushWorkItem?.cancel()
                flushWorkItem = nil
                pendingText = nil
                snapshotOpacity = 1.0
            }
    }

    private func scheduleRenderUpdate(with newText: String) {
        guard newText != renderedText else { return }
        if renderedText.isEmpty {
            renderedText = newText
            return
        }

        pendingText = newText
        guard flushWorkItem == nil else { return }
        scheduleFlush()
    }

    private func scheduleFlush() {
        let work = DispatchWorkItem {
            flushWorkItem = nil
            guard let pendingText else { return }
            renderedText = pendingText
            self.pendingText = nil
            animateSnapshotArrival()
            onSnapshotRendered?()
        }

        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval, execute: work)
    }

    private func animateSnapshotArrival() {
        snapshotOpacity = 0.94
        withAnimation(.easeOut(duration: 0.14)) {
            snapshotOpacity = 1.0
        }
    }
}

// MARK: - Full message bubble (used in conversation)

struct MessageBubbleView: View {
    @ObserveInjection var inject
    private let renderCache = MessageRenderCache.shared
    let message: ChatMessage
    let serverId: String?
    let agentDirectoryVersion: Int
    let textScale: CGFloat
    let isStreamingMessage: Bool
    let actionsDisabled: Bool
    let onStreamingSnapshotRendered: (() -> Void)?
    let resolveTargetLabel: ((String) -> String?)?
    let onWidgetPrompt: ((String) -> Void)?
    let onEditUserMessage: ((ChatMessage) -> Void)?
    let onForkFromUserMessage: ((ChatMessage) -> Void)?
    @ScaledMetric(relativeTo: .body) private var mdBodySize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var mdCodeSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var mdSystemBodySize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var mdSystemCodeSize: CGFloat = 12

    init(
        message: ChatMessage,
        serverId: String? = nil,
        agentDirectoryVersion: Int = 0,
        textScale: CGFloat = 1.0,
        isStreamingMessage: Bool = false,
        actionsDisabled: Bool = false,
        onStreamingSnapshotRendered: (() -> Void)? = nil,
        resolveTargetLabel: ((String) -> String?)? = nil,
        onWidgetPrompt: ((String) -> Void)? = nil,
        onEditUserMessage: ((ChatMessage) -> Void)? = nil,
        onForkFromUserMessage: ((ChatMessage) -> Void)? = nil
    ) {
        self.message = message
        self.serverId = serverId
        self.agentDirectoryVersion = agentDirectoryVersion
        self.textScale = textScale
        self.isStreamingMessage = isStreamingMessage
        self.actionsDisabled = actionsDisabled
        self.onStreamingSnapshotRendered = onStreamingSnapshotRendered
        self.resolveTargetLabel = resolveTargetLabel
        self.onWidgetPrompt = onWidgetPrompt
        self.onEditUserMessage = onEditUserMessage
        self.onForkFromUserMessage = onForkFromUserMessage
    }

    var body: some View {
        Group {
            if message.role == .user {
                userBubbleWithActions
            } else if message.role == .assistant {
                assistantContent
            } else if isReasoning {
                HStack(alignment: .top, spacing: 0) {
                    reasoningContent
                    Spacer(minLength: 20)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    systemBubble
                    Spacer(minLength: 20)
                }
            }
        }
        .enableInjection()
    }

    private var renderRevisionKey: MessageRenderCache.RevisionKey {
        MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: serverId,
            agentDirectoryVersion: agentDirectoryVersion,
            isStreaming: isStreamingMessage
        )
    }

    private var isReasoning: Bool {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return false }
        let firstLine = trimmed.prefix(while: { $0 != "\n" })
        return firstLine.lowercased().contains("reason")
    }

    private var supportsUserActions: Bool {
        message.role == .user &&
            message.isFromUserTurnBoundary &&
            message.sourceTurnIndex != nil
    }

    private var userBubbleWithActions: some View {
        UserBubble(text: message.text, images: message.images, textScale: textScale)
            .contextMenu {
                if supportsUserActions {
                    Button("Edit Message") {
                        onEditUserMessage?(message)
                    }
                    .disabled(actionsDisabled || onEditUserMessage == nil)

                    Button("Fork From Here") {
                        onForkFromUserMessage?(message)
                    }
                    .disabled(actionsDisabled || onForkFromUserMessage == nil)
                }
            }
    }

    @ViewBuilder
    private var assistantContent: some View {
        if isStreamingMessage {
            StreamingAssistantBubble(
                text: message.text,
                label: assistantAgentLabel,
                textScale: textScale,
                onSnapshotRendered: onStreamingSnapshotRendered
            )
        } else {
            let parsed = assistantSegmentsForRendering
            let hasImages = parsed.contains { if case .image = $0.kind { return true } else { return false } }

            if !hasImages {
                if let first = parsed.first,
                   case let .markdown(content, identity) = first.kind {
                    AssistantBubble(
                        markdownContent: content,
                        markdownIdentity: identity,
                        label: assistantAgentLabel,
                        textScale: textScale
                    )
                } else {
                    AssistantBubble(text: message.text, label: assistantAgentLabel, textScale: textScale)
                }
            } else {
                // Inline images — need segment-based rendering
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let assistantLabel = assistantAgentLabel {
                            Text(assistantLabel)
                                .font(LitterFont.styled(.caption2, weight: .semibold, scale: textScale))
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        ForEach(parsed) { segment in
                            switch segment.kind {
                            case .markdown(let content, _):
                                Markdown(content)
                                    .markdownTheme(.litter(bodySize: mdBodySize * textScale, codeSize: mdCodeSize * textScale))
                                    .markdownCodeSyntaxHighlighter(.plain)
                                    .textSelection(.enabled)
                            case .image(let uiImage):
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 300)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 20)
                }
            }
        }
    }

    private var assistantAgentLabel: String? {
        AgentLabelFormatter.format(
            nickname: message.agentNickname,
            role: message.agentRole
        )
    }

    private var reasoningContent: some View {
        let (_, body) = extractSystemTitleAndBody(message.text)
        return Text(normalizedReasoningText(body))
            .font(LitterFont.styled(.footnote, scale: textScale))
            .italic()
            .foregroundColor(LitterTheme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var systemBubble: some View {
        if let widget = message.widgetState {
            WidgetContainerView(
                widget: widget,
                onMessage: handleWidgetMessage,
                textScale: textScale
            )
        } else {
            let parsed = systemParseResultForRendering
            switch parsed {
            case .recognized(let model):
                ToolCallCardView(model: model, textScale: textScale)
            case .unrecognized:
                genericSystemBubble
            }
        }
    }

    private func handleWidgetMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["_type"] as? String else { return }
        switch type {
        case "sendPrompt":
            if let text = dict["text"] as? String, !text.isEmpty {
                onWidgetPrompt?(text)
            }
        case "openLink":
            if let urlStr = dict["url"] as? String, let url = URL(string: urlStr) {
                UIApplication.shared.open(url)
            }
        default:
            break
        }
    }

    private var genericSystemBubble: some View {
        let (title, body) = extractSystemTitleAndBody(message.text)
        let markdown = title == nil ? message.text : body
        let displayTitle = title ?? "System"
        let content = renderCache.markdownContent(
            for: markdown,
            key: renderRevisionKey,
            fragmentId: "system-generic"
        )

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11 * textScale, weight: .semibold))
                    .foregroundColor(LitterTheme.accent)
                Text(displayTitle.uppercased())
                    .font(LitterFont.styled(.caption2, weight: .bold, scale: textScale))
                    .foregroundColor(LitterTheme.accent)
                Spacer()
            }

            if !markdown.isEmpty {
                Markdown(content)
                    .markdownTheme(.litterSystem(bodySize: mdSystemBodySize * textScale, codeSize: mdSystemCodeSize * textScale))
                    .markdownCodeSyntaxHighlighter(.plain)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(GlassRectModifier(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(LitterTheme.accent.opacity(0.9))
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func extractSystemTitleAndBody(_ text: String) -> (String?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return (nil, trimmed) }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (nil, trimmed) }
        let title = first.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : title, body)
    }

    private func normalizedReasoningText(_ body: String) -> String {
        body
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 {
                    return String(trimmed.dropFirst(2).dropLast(2))
                }
                return line
            }
            .joined(separator: "\n")
    }

    private var assistantSegmentsForRendering: [MessageRenderCache.AssistantSegment] {
        renderCache.assistantSegments(
            for: message,
            key: renderRevisionKey
        )
    }

    private var systemParseResultForRendering: ToolCallParseResult {
        renderCache.systemParseResult(
            for: message,
            key: renderRevisionKey,
            resolveTargetLabel: resolveTargetLabel
        )
    }
}

// MARK: - Plain syntax highlighter (no highlighting, just monospace)

struct PlainSyntaxHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        Text(code)
    }
}

extension CodeSyntaxHighlighter where Self == PlainSyntaxHighlighter {
    static var plain: PlainSyntaxHighlighter { PlainSyntaxHighlighter() }
}

// MARK: - Litter Markdown Theme

extension MarkdownUI.Theme {
    static func litter(bodySize: CGFloat, codeSize: CGFloat) -> Theme {
        Theme()
            .text {
                ForegroundColor(LitterTheme.textBody)
                FontFamily(.custom(LitterFont.markdownFontName))
                FontSize(bodySize)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(bodySize * 1.43)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.21)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.07)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(LitterTheme.textPrimary)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(LitterTheme.accent)
            }
            .code {
                FontFamily(.custom(LitterFont.markdownFontName))
                FontSize(codeSize)
                ForegroundColor(LitterTheme.accent)
                BackgroundColor(LitterTheme.surface)
            }
            .codeBlock { configuration in
                CodeBlockView(
                    language: configuration.language ?? "",
                    code: configuration.content,
                    fontSize: codeSize
                )
                .markdownMargin(top: 8, bottom: 8)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(LitterTheme.textSecondary)
                        FontStyle(.italic)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(LitterTheme.border)
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 8, bottom: 8)
            }
            .thematicBreak {
                Divider()
                    .overlay(LitterTheme.border)
                    .markdownMargin(top: 12, bottom: 12)
            }
    }

    static func litterSystem(bodySize: CGFloat, codeSize: CGFloat) -> Theme {
        Theme()
            .text {
                ForegroundColor(LitterTheme.textSystem)
                FontFamily(.custom(LitterFont.markdownFontName))
                FontSize(bodySize)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(bodySize * 1.31)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.15)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.08)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(LitterTheme.textPrimary)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(LitterTheme.accent)
            }
            .code {
                FontFamily(.custom(LitterFont.markdownFontName))
                FontSize(codeSize)
                ForegroundColor(LitterTheme.accent)
                BackgroundColor(LitterTheme.surface)
            }
            .codeBlock { configuration in
                CodeBlockView(
                    language: configuration.language ?? "",
                    code: configuration.content,
                    fontSize: codeSize
                )
                .markdownMargin(top: 6, bottom: 6)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 3, bottom: 3)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(LitterTheme.textSecondary)
                        FontStyle(.italic)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(LitterTheme.border)
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 6, bottom: 6)
            }
            .thematicBreak {
                Divider()
                    .overlay(LitterTheme.border)
                    .markdownMargin(top: 8, bottom: 8)
            }
    }
}

#if DEBUG
#Preview("Message Bubbles") {
    LitterPreviewScene {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(LitterPreviewData.sampleMessages) { message in
                    MessageBubbleView(
                        message: message,
                        serverId: LitterPreviewData.sampleServer.id
                    )
                }
            }
            .padding(16)
        }
    }
}
#endif
