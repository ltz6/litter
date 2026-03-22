import Foundation

enum CrossServerTools {
    static let listServersToolName = "list_servers"
    static let listSessionsToolName = "list_sessions"
    static let readSessionToolName = "read_session"
    static let runOnServerToolName = "run_on_server"

    /// Build the dynamic tool specs for cross-server operations.
    static func buildDynamicToolSpecs() -> [DynamicToolSpecParams] {
        [
            listServersSpec(),
            listSessionsSpec(),
            readSessionSpec(),
            runOnServerSpec()
        ]
    }

    /// Returns true if the given tool name is a cross-server tool that
    /// should be rendered with rich formatting in the conversation timeline.
    static func isRichTool(_ toolName: String) -> Bool {
        switch toolName {
        case listServersToolName, listSessionsToolName, readSessionToolName, runOnServerToolName:
            return true
        default:
            return false
        }
    }

    private static func listServersSpec() -> DynamicToolSpecParams {
        DynamicToolSpecParams(
            name: listServersToolName,
            description: "List all connected servers and their status.",
            inputSchema: AnyEncodable(JSONSchema.object([:], required: []))
        )
    }

    private static func listSessionsSpec() -> DynamicToolSpecParams {
        DynamicToolSpecParams(
            name: listSessionsToolName,
            description: "List recent sessions/threads on a specific server or all connected servers.",
            inputSchema: AnyEncodable(JSONSchema.object([
                "server": .string(description: "Server name to query. Omit to query all connected servers.")
            ], required: []))
        )
    }

    private static func readSessionSpec() -> DynamicToolSpecParams {
        DynamicToolSpecParams(
            name: readSessionToolName,
            description: "Read the full conversation history of a session on a specific server.",
            inputSchema: AnyEncodable(JSONSchema.object([
                "server": .string(description: "Server name where the session lives."),
                "session_id": .string(description: "The session/thread ID to read.")
            ], required: ["server", "session_id"]))
        )
    }

    private static func runOnServerSpec() -> DynamicToolSpecParams {
        DynamicToolSpecParams(
            name: runOnServerToolName,
            description: "Run a prompt on a remote server. Creates or reuses a thread and waits for the turn to complete.",
            inputSchema: AnyEncodable(JSONSchema.object([
                "server": .string(description: "Server name to run the prompt on."),
                "prompt": .string(description: "The prompt to send.")
            ], required: ["server", "prompt"]))
        )
    }
}
