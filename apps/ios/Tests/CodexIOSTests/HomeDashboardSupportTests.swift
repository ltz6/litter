import XCTest
@testable import Litter

@MainActor
final class HomeDashboardSupportTests: XCTestCase {
    func testRecentConnectedSessionsFiltersDisconnectedServersAndLimitsToThreeNewest() {
        let threads = [
            makeThread(serverId: "server-b", threadId: "b-older", updatedAt: 20),
            makeThread(serverId: "server-a", threadId: "a-newest", updatedAt: 50),
            makeThread(serverId: "server-c", threadId: "c-disconnected", updatedAt: 60),
            makeThread(serverId: "server-a", threadId: "a-mid", updatedAt: 40),
            makeThread(serverId: "server-b", threadId: "b-mid", updatedAt: 30),
            makeThread(serverId: "server-a", threadId: "a-oldest", updatedAt: 10)
        ]

        let result = HomeDashboardSupport.recentConnectedSessions(
            from: threads,
            connectedServerIds: ["server-a", "server-b"],
            limit: 3
        )

        XCTAssertEqual(result.map(\.threadId), ["a-newest", "a-mid", "b-mid"])
    }

    func testDefaultConnectedServerIdPrefersPreferredThenActiveThenFirstConnected() {
        XCTAssertEqual(
            SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds: ["server-a", "server-b"],
                activeThreadKey: ThreadKey(serverId: "server-b", threadId: "thread-1"),
                preferredServerId: "server-a"
            ),
            "server-a"
        )

        XCTAssertEqual(
            SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds: ["server-a", "server-b"],
                activeThreadKey: ThreadKey(serverId: "server-b", threadId: "thread-1"),
                preferredServerId: "server-missing"
            ),
            "server-b"
        )

        XCTAssertEqual(
            SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds: ["server-a", "server-b"],
                activeThreadKey: nil,
                preferredServerId: nil
            ),
            "server-a"
        )

        XCTAssertNil(
            SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds: [],
                activeThreadKey: nil,
                preferredServerId: nil
            )
        )
    }

    private func makeThread(serverId: String, threadId: String, updatedAt: TimeInterval) -> ThreadState {
        let thread = ThreadState(
            serverId: serverId,
            threadId: threadId,
            serverName: serverId,
            serverSource: .manual
        )
        thread.preview = threadId
        thread.updatedAt = Date(timeIntervalSince1970: updatedAt)
        return thread
    }
}
