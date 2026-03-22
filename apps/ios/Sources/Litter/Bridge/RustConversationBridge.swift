import Foundation

enum RustConversationBridge {

    static func conversationItems(from items: [HydratedConversationItem]) -> [ConversationItem] {
        items.map(\.toConversationItem)
    }

    static func hydrateItem(
        item: ThreadItem,
        turnId: String?,
        defaultAgentNickname: String?,
        defaultAgentRole: String?,
        isInProgressEvent: Bool = false
    ) -> ConversationItem? {
        guard var item = try? CodexSharedClient.shared.hydrateThreadItem(
            item: item,
            turnId: turnId,
            defaultAgentNickname: defaultAgentNickname,
            defaultAgentRole: defaultAgentRole
        ) else {
            return nil
        }

        if isInProgressEvent,
           case .divider(.contextCompaction(let isComplete)) = item.content,
           isComplete {
            item.content = .divider(.contextCompaction(isComplete: false))
        }

        return item.toConversationItem
    }
}

private extension HydratedConversationItem {
    var toConversationItem: ConversationItem {
        ConversationItem(
            id: id,
            content: content.toConversationItemContent,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex.map(Int.init),
            timestamp: timestamp.map(Date.init(timeIntervalSince1970:)) ?? Date(),
            isFromUserTurnBoundary: isFromUserTurnBoundary
        )
    }
}

private extension HydratedConversationItemContent {
    var toConversationItemContent: ConversationItemContent {
        switch self {
        case .user(let data):
            let images = data.imageDataUris.compactMap(decodeBase64DataURI(_:)).map { ChatImage(data: $0) }
            return .user(ConversationUserMessageData(text: data.text, images: images))
        case .assistant(let data):
            return .assistant(
                ConversationAssistantMessageData(
                    text: data.text,
                    agentNickname: data.agentNickname,
                    agentRole: data.agentRole
                )
            )
        case .reasoning(let data):
            return .reasoning(ConversationReasoningData(summary: data.summary, content: data.content))
        case .todoList(let data):
            return .todoList(
                ConversationTodoListData(
                    steps: data.steps.map {
                        ConversationPlanStep(step: $0.step, status: planStepStatus(from: $0.status))
                    }
                )
            )
        case .proposedPlan(let data):
            return .proposedPlan(ConversationProposedPlanData(content: data.content))
        case .commandExecution(let data):
            return .commandExecution(
                ConversationCommandExecutionData(
                    command: data.command,
                    cwd: data.cwd,
                    status: data.status,
                    output: data.output,
                    exitCode: data.exitCode.map(Int.init),
                    durationMs: data.durationMs.map(Int.init),
                    processId: data.processId,
                    actions: data.actions.map {
                        ConversationCommandAction(
                            kind: commandActionKind(from: $0.kind),
                            command: $0.command,
                            name: $0.name,
                            path: $0.path,
                            query: $0.query
                        )
                    }
                )
            )
        case .fileChange(let data):
            return .fileChange(
                ConversationFileChangeData(
                    status: data.status,
                    changes: data.changes.map {
                        ConversationFileChangeEntry(path: $0.path, kind: $0.kind, diff: $0.diff)
                    },
                    outputDelta: nil
                )
            )
        case .mcpToolCall(let data):
            return .mcpToolCall(
                ConversationMcpToolCallData(
                    server: data.server,
                    tool: data.tool,
                    status: data.status,
                    durationMs: data.durationMs.map(Int.init),
                    argumentsJSON: data.argumentsJson,
                    contentSummary: data.contentSummary,
                    structuredContentJSON: data.structuredContentJson,
                    rawOutputJSON: data.rawOutputJson,
                    errorMessage: data.errorMessage,
                    progressMessages: []
                )
            )
        case .dynamicToolCall(let data):
            return .dynamicToolCall(
                ConversationDynamicToolCallData(
                    tool: data.tool,
                    status: data.status,
                    durationMs: data.durationMs.map(Int.init),
                    success: data.success,
                    argumentsJSON: data.argumentsJson,
                    contentSummary: data.contentSummary
                )
            )
        case .multiAgentAction(let data):
            return .multiAgentAction(
                ConversationMultiAgentActionData(
                    tool: data.tool,
                    status: data.status,
                    prompt: data.prompt,
                    targets: data.targets,
                    receiverThreadIds: data.receiverThreadIds,
                    agentStates: data.agentStates.map {
                        ConversationMultiAgentState(
                            targetId: $0.targetId,
                            status: $0.status,
                            message: $0.message
                        )
                    }
                )
            )
        case .webSearch(let data):
            return .webSearch(
                ConversationWebSearchData(
                    query: data.query,
                    actionJSON: data.actionJson,
                    isInProgress: data.isInProgress
                )
            )
        case .divider(let data):
            switch data {
            case .contextCompaction(let isComplete):
                return .divider(.contextCompaction(isComplete: isComplete))
            case .reviewEntered(let review):
                return .divider(.reviewEntered(review))
            case .reviewExited(let review):
                return .divider(.reviewExited(review))
            }
        case .note(let data):
            return .note(ConversationNoteData(title: data.title, body: data.body))
        }
    }
}

private func decodeBase64DataURI(_ uri: String) -> Data? {
    guard uri.hasPrefix("data:") else {
        if uri.hasPrefix("file://") {
            let path = String(uri.dropFirst("file://".count))
            return FileManager.default.contents(atPath: path)
        }
        return nil
    }
    guard let commaIndex = uri.firstIndex(of: ",") else { return nil }
    let base64 = String(uri[uri.index(after: commaIndex)...])
    return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
}

private func planStepStatus(from raw: String) -> ConversationPlanStepStatus {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "completed":
        return .completed
    case "inprogress", "in_progress":
        return .inProgress
    default:
        return .pending
    }
}

private func commandActionKind(from raw: String) -> ConversationCommandActionKind {
    switch raw {
    case "read":
        return .read
    case "search":
        return .search
    case "listFiles":
        return .listFiles
    default:
        return .unknown
    }
}
