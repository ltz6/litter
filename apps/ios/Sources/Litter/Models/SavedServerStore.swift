import Foundation

@MainActor
enum SavedServerStore {
    private static let savedServersKey = "codex_saved_servers"

    static func save(_ servers: [SavedServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: savedServersKey)
    }

    static func load() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey) else { return [] }
        let decoded = (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
        let migrated = decoded.map { saved -> SavedServer in
            let server = saved.toDiscoveredServer()
            return SavedServer.from(server)
        }
        if migrated != decoded {
            save(migrated)
        }
        return migrated
    }

    static func upsert(_ server: DiscoveredServer) {
        var saved = load()
        saved.removeAll { existing in
            existing.id == server.id || existing.toDiscoveredServer().deduplicationKey == server.deduplicationKey
        }
        saved.append(SavedServer.from(server))
        save(saved)
    }

    static func remove(serverId: String) {
        var saved = load()
        saved.removeAll { $0.id == serverId }
        save(saved)
    }

    static func rename(serverId: String, newName: String) {
        var saved = load()
        guard let index = saved.firstIndex(where: { $0.id == serverId }) else { return }
        let old = saved[index]
        saved[index] = SavedServer(
            id: old.id,
            name: newName,
            hostname: old.hostname,
            port: old.port,
            codexPorts: old.codexPorts,
            sshPort: old.sshPort,
            source: old.source,
            hasCodexServer: old.hasCodexServer,
            wakeMAC: old.wakeMAC,
            preferredConnectionMode: old.preferredConnectionMode,
            preferredCodexPort: old.preferredCodexPort,
            sshPortForwardingEnabled: old.sshPortForwardingEnabled,
            websocketURL: old.websocketURL
        )
        save(saved)
    }
}
