import XCTest
@testable import Litter

@MainActor
final class PerformanceHelpersTests: XCTestCase {
    func testTranscriptTurnBuilderCollapsesPreviousTurnOnceANewLiveTurnStarts() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let turns = TranscriptTurn.build(
            from: [
                ChatMessage(role: .user, text: "Turn 1", sourceTurnId: "turn-1", sourceTurnIndex: 0, isFromUserTurnBoundary: true, timestamp: baseTime),
                ChatMessage(role: .assistant, text: "Reply 1", sourceTurnId: "turn-1", sourceTurnIndex: 0, timestamp: baseTime.addingTimeInterval(0.3)),
                ChatMessage(role: .user, text: "Turn 2", sourceTurnId: "turn-2", sourceTurnIndex: 1, isFromUserTurnBoundary: true, timestamp: baseTime.addingTimeInterval(1)),
                ChatMessage(role: .assistant, text: "Reply 2", sourceTurnId: "turn-2", sourceTurnIndex: 1, timestamp: baseTime.addingTimeInterval(1.6)),
                ChatMessage(role: .user, text: "Turn 3", sourceTurnId: "turn-3", sourceTurnIndex: 2, isFromUserTurnBoundary: true, timestamp: baseTime.addingTimeInterval(2)),
                ChatMessage(role: .system, text: "### Command Execution\nStatus: completed", sourceTurnId: "turn-3", sourceTurnIndex: 2, timestamp: baseTime.addingTimeInterval(4.2)),
                ChatMessage(role: .assistant, text: "Reply 3", sourceTurnId: "turn-3", sourceTurnIndex: 2, timestamp: baseTime.addingTimeInterval(5.2)),
                ChatMessage(role: .user, text: "Turn 4", isFromUserTurnBoundary: true, timestamp: baseTime.addingTimeInterval(6)),
                ChatMessage(role: .assistant, text: "Streaming reply", timestamp: baseTime.addingTimeInterval(6.4))
            ],
            threadStatus: .thinking,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 4)
        XCTAssertTrue(turns[0].isCollapsedByDefault)
        XCTAssertTrue(turns[1].isCollapsedByDefault)
        XCTAssertTrue(turns[2].isCollapsedByDefault)
        XCTAssertTrue(turns[3].isLive)
        XCTAssertFalse(turns[3].isCollapsedByDefault)
        XCTAssertEqual(turns[2].preview.secondaryText, "Reply 3")
        XCTAssertEqual(turns[2].preview.toolCallCount, 1)
        XCTAssertEqual(turns[2].preview.durationText, "3.2s")
    }

    func testTranscriptTurnBuilderUsesUserToAssistantDuration() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let turns = TranscriptTurn.build(
            from: [
                ChatMessage(
                    role: .user,
                    text: "Inspect repo",
                    sourceTurnId: "turn-1",
                    sourceTurnIndex: 0,
                    isFromUserTurnBoundary: true,
                    timestamp: baseTime
                ),
                ChatMessage(
                    role: .system,
                    text: """
                    ### Command Execution
                    Status: completed
                    Duration: 840 ms
                    """,
                    sourceTurnId: "turn-1",
                    sourceTurnIndex: 0,
                    timestamp: baseTime.addingTimeInterval(0.2)
                ),
                ChatMessage(
                    role: .assistant,
                    text: "Done",
                    sourceTurnId: "turn-1",
                    sourceTurnIndex: 0,
                    timestamp: baseTime.addingTimeInterval(0.84)
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].preview.durationText, "840ms")
        XCTAssertEqual(turns[0].preview.toolCallCount, 1)
    }

    func testTranscriptTurnBuilderProducesUniqueIDsWhenSourceTurnIDRepeatsAcrossBoundarySplits() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let repeatedSourceTurnId = "turn-1"
        let turns = TranscriptTurn.build(
            from: [
                ChatMessage(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    role: .user,
                    text: "First question",
                    sourceTurnId: repeatedSourceTurnId,
                    sourceTurnIndex: 0,
                    isFromUserTurnBoundary: true,
                    timestamp: baseTime
                ),
                ChatMessage(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111112")!,
                    role: .assistant,
                    text: "First answer",
                    sourceTurnId: repeatedSourceTurnId,
                    sourceTurnIndex: 0,
                    timestamp: baseTime.addingTimeInterval(0.5)
                ),
                ChatMessage(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111113")!,
                    role: .user,
                    text: "Follow-up",
                    sourceTurnId: repeatedSourceTurnId,
                    sourceTurnIndex: 0,
                    isFromUserTurnBoundary: true,
                    timestamp: baseTime.addingTimeInterval(1)
                ),
                ChatMessage(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111114")!,
                    role: .assistant,
                    text: "Follow-up answer",
                    sourceTurnId: repeatedSourceTurnId,
                    sourceTurnIndex: 0,
                    timestamp: baseTime.addingTimeInterval(1.5)
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(Set(turns.map(\.id)).count, 2)
        XCTAssertNotEqual(turns[0].id, turns[1].id)
    }

    func testTranscriptTurnBuilderFallsBackToExplicitDurationForRestoredHistory() {
        let restoredAt = Date(timeIntervalSince1970: 200)
        let turns = TranscriptTurn.build(
            from: [
                ChatMessage(
                    role: .user,
                    text: "Inspect repo",
                    sourceTurnId: "turn-1",
                    sourceTurnIndex: 0,
                    isFromUserTurnBoundary: true,
                    timestamp: restoredAt
                ),
                ChatMessage(
                    role: .system,
                    text: """
                    ### Command Execution
                    Status: completed
                    Duration: 840 ms
                    """,
                    sourceTurnId: "turn-1",
                    sourceTurnIndex: 0,
                    timestamp: restoredAt.addingTimeInterval(0.01)
                ),
                ChatMessage(
                    role: .assistant,
                    text: "Done",
                    sourceTurnId: "turn-1",
                    sourceTurnIndex: 0,
                    timestamp: restoredAt.addingTimeInterval(0.02)
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].preview.durationText, "840ms")
    }

    func testResumedThreadItemDecodesTimestamp() throws {
        let data = Data(
            """
            {
              "type": "agentMessage",
              "text": "Done",
              "timestamp": "2025-01-05T12:00:00Z"
            }
            """.utf8
        )

        let item = try JSONDecoder().decode(ResumedThreadItem.self, from: data)
        let timestamp = try XCTUnwrap(item.timestamp)
        XCTAssertEqual(timestamp.timeIntervalSince1970, 1_736_078_400, accuracy: 0.001)
    }

    func testResumedThreadItemDecodesCreatedAtMillisecondsTimestamp() throws {
        let data = Data(
            """
            {
              "type": "agentMessage",
              "text": "Done",
              "created_at": 1736078400000
            }
            """.utf8
        )

        let item = try JSONDecoder().decode(ResumedThreadItem.self, from: data)
        let timestamp = try XCTUnwrap(item.timestamp)
        XCTAssertEqual(timestamp.timeIntervalSince1970, 1_736_078_400, accuracy: 0.001)
    }

    func testMessageRenderCacheReusesStableAssistantRevisionKey() {
        let cache = MessageRenderCache()
        let base64Pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn8Vf0AAAAASUVORK5CYII="
        let messageText = "Hello ![](data:image/png;base64,\(base64Pixel))"
        var message = ChatMessage(role: .assistant, text: messageText)

        let key = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        XCTAssertEqual(cache.assistantEntryCount, 0)

        _ = cache.assistantSegments(for: message, key: key)
        XCTAssertEqual(cache.assistantEntryCount, 1)
        XCTAssertEqual(cache.markdownEntryCount, 1)

        _ = cache.assistantSegments(for: message, key: key)
        XCTAssertEqual(cache.assistantEntryCount, 1)
        XCTAssertEqual(cache.markdownEntryCount, 1)

        message.text += "\nMore"
        let changedKey = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        _ = cache.assistantSegments(for: message, key: changedKey)
        XCTAssertEqual(cache.assistantEntryCount, 2)
        XCTAssertEqual(cache.markdownEntryCount, 3)
    }

    func testMessageRenderCacheScopesSystemEntriesByAgentDirectoryRevision() {
        let cache = MessageRenderCache()
        let message = ChatMessage(
            role: .system,
            text: """
            ### Collaboration
            Status: completed
            Tool: ask_agent
            Targets: thread-alpha
            """
        )

        let key0 = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        let key1 = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 1,
            isStreaming: false
        )

        _ = cache.systemParseResult(for: message, key: key0, resolveTargetLabel: { _ in "Planner [lead]" })
        XCTAssertEqual(cache.systemEntryCount, 1)

        _ = cache.systemParseResult(for: message, key: key0, resolveTargetLabel: { _ in "Planner [lead]" })
        XCTAssertEqual(cache.systemEntryCount, 1)

        _ = cache.systemParseResult(for: message, key: key1, resolveTargetLabel: { _ in "Builder [worker]" })
        XCTAssertEqual(cache.systemEntryCount, 2)
    }

    func testSessionsModelFreezesMostRecentOrderingWhileThreadIsActive() async {
        let serverManager = ServerManager()
        let appState = AppState()
        appState.sessionSidebarWorkspaceSortModeRaw = WorkspaceSortMode.mostRecent.rawValue

        let olderThread = makeThreadState(threadId: "older", updatedAt: 10)
        let streamingThread = makeThreadState(threadId: "streaming", updatedAt: 5)

        serverManager.threads = [
            olderThread.key: olderThread,
            streamingThread.key: streamingThread
        ]

        let sessionsModel = SessionsModel()
        sessionsModel.bind(serverManager: serverManager, appState: appState)
        XCTAssertEqual(sessionsModel.derivedData.allThreadKeys.map(\.threadId), ["older", "streaming"])

        streamingThread.status = .thinking
        await flushMainQueue()

        streamingThread.updatedAt = Date(timeIntervalSince1970: 20)
        await flushMainQueue()
        XCTAssertEqual(sessionsModel.derivedData.allThreadKeys.map(\.threadId), ["older", "streaming"])

        streamingThread.status = .ready
        await flushMainQueue()
        XCTAssertEqual(sessionsModel.derivedData.allThreadKeys.map(\.threadId), ["streaming", "older"])
    }

    func testChatMessageRenderDigestChangesWhenMarkdownChanges() {
        var message = ChatMessage(role: .assistant, text: "# Title")
        let originalDigest = message.renderDigest

        message.text = """
        # Title

        ```swift
        print("updated")
        ```
        """

        XCTAssertNotEqual(message.renderDigest, originalDigest)
    }

    private func makeThreadState(threadId: String, updatedAt: TimeInterval) -> ThreadState {
        let thread = ThreadState(
            serverId: "server-a",
            threadId: threadId,
            serverName: "Server",
            serverSource: .local
        )
        thread.preview = threadId
        thread.cwd = "/tmp/\(threadId)"
        thread.updatedAt = Date(timeIntervalSince1970: updatedAt)
        return thread
    }

    private func flushMainQueue() async {
        await Task.yield()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
