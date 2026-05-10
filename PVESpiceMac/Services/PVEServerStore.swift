import Foundation
import SwiftUI

@MainActor
final class PVEServerStore: ObservableObject {
    @Published private(set) var servers: [PVEServerRecord] = []

    private let defaultsKey = "pvespice.pve.servers.v1"

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            servers = []
            return
        }
        do {
            servers = try JSONDecoder().decode([PVEServerRecord].self, from: data)
        } catch {
            servers = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(servers)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            assertionFailure("PVEServerRecord encode: \(error)")
        }
    }

    func upsert(_ record: PVEServerRecord, password: String) throws {
        try KeychainStore.setPassword(password, forServerID: record.id)
        if let idx = servers.firstIndex(where: { $0.id == record.id }) {
            servers[idx] = record
        } else {
            servers.append(record)
        }
        servers.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        save()
    }

    func delete(id: UUID) throws {
        servers.removeAll { $0.id == id }
        try KeychainStore.deletePassword(forServerID: id)
        save()
    }

    func record(id: UUID) -> PVEServerRecord? {
        servers.first { $0.id == id }
    }

    func password(for id: UUID) throws -> String? {
        try KeychainStore.password(forServerID: id)
    }
}
