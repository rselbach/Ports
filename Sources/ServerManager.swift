import Foundation
import os

struct SavedServer: Codable {
    let port: UInt16
    let directoryPath: String
    let exposeToLAN: Bool

    init(port: UInt16, directoryPath: String, exposeToLAN: Bool) {
        self.port = port
        self.directoryPath = directoryPath
        self.exposeToLAN = exposeToLAN
    }

    private enum CodingKeys: String, CodingKey {
        case port
        case directoryPath
        case exposeToLAN
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(UInt16.self, forKey: .port)
        directoryPath = try container.decode(String.self, forKey: .directoryPath)
        exposeToLAN = try container.decodeIfPresent(Bool.self, forKey: .exposeToLAN) ?? false
    }
}

final class ServerManager: HTTPServerDelegate {
    private let savedServersKey = "savedServers"
    private let portScanner: PortScanner
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.ports",
        category: "ServerManager"
    )
    private var activeServers: [HTTPServer] = []
    private let activeServersLock = NSLock()

    var onServerFailure: ((HTTPServer, Error) -> Void)?

    init(portScanner: PortScanner) {
        self.portScanner = portScanner
    }

    func snapshotServers() -> [HTTPServer] {
        activeServersLock.lock()
        let snapshot = activeServers
        activeServersLock.unlock()
        return snapshot
    }

    func isPortInUse(_ port: UInt16) -> Bool {
        if snapshotServers().contains(where: { $0.port == port }) {
            return true
        }
        return portScanner.scan().contains(where: { $0.port == port })
    }

    func findAvailablePort(defaultPort: UInt16) -> UInt16 {
        let startPort = Int(defaultPort)
        let endPort = min(startPort + 100, Int(UInt16.max))
        for port in startPort...endPort {
            guard let candidate = UInt16(exactly: port) else {
                continue
            }
            if !isPortInUse(candidate) {
                return candidate
            }
        }
        return UInt16.random(in: 8200...9000)
    }

    func startServer(port: UInt16, directory: URL, exposeToLAN: Bool) throws {
        let server = HTTPServer(port: port, directory: directory, exposeToLAN: exposeToLAN)
        server.delegate = self
        try server.start()
        addServer(server)
        saveServers()
    }

    func stopServer(_ server: HTTPServer) {
        stopServers([server])
    }

    func stopServers(_ servers: [HTTPServer]) {
        servers.forEach { $0.stop() }
        servers.forEach { removeServer($0) }
        saveServers()
    }

    func stopAllServers() {
        stopServers(snapshotServers())
    }

    func restoreServers() -> [HTTPServer] {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey) else {
            return []
        }

        let saved: [SavedServer]
        do {
            saved = try JSONDecoder().decode([SavedServer].self, from: data)
        } catch {
            logger.error("Failed to decode persisted servers: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let usedPorts = Set(portScanner.scan().map { $0.port })
        var reservedPorts = Set<UInt16>()
        var restoredLANServers: [HTTPServer] = []

        for entry in saved {
            let directory = URL(fileURLWithPath: entry.directoryPath)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }

            var port = entry.port
            let takenPorts = reservedPorts
                .union(usedPorts)
                .union(Set(snapshotServers().map { $0.port }))
            if takenPorts.contains(port) {
                port = findAvailablePortExcluding(takenPorts)
            }
            reservedPorts.insert(port)

            let server = HTTPServer(port: port, directory: directory, exposeToLAN: entry.exposeToLAN)
            server.delegate = self
            do {
                try server.start()
                addServer(server)
                if entry.exposeToLAN {
                    restoredLANServers.append(server)
                }
            } catch {
                logger.error("Failed to restore server on port \(port): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !snapshotServers().isEmpty {
            saveServers()
        }

        return restoredLANServers
    }

    func saveServers() {
        guard AppSettings.shared.persistServers else {
            UserDefaults.standard.removeObject(forKey: savedServersKey)
            return
        }

        let saved = snapshotServers().map {
            SavedServer(port: $0.port, directoryPath: $0.directory.path, exposeToLAN: $0.exposeToLAN)
        }

        do {
            let data = try JSONEncoder().encode(saved)
            UserDefaults.standard.set(data, forKey: savedServersKey)
        } catch {
            logger.error("Failed to encode persisted servers: \(error.localizedDescription, privacy: .public)")
        }
    }

    func server(_ server: HTTPServer, didFailWithError error: Error) {
        removeServer(server)
        saveServers()
        DispatchQueue.main.async { [weak self] in
            self?.onServerFailure?(server, error)
        }
    }

    private func addServer(_ server: HTTPServer) {
        activeServersLock.lock()
        activeServers.append(server)
        activeServersLock.unlock()
    }

    private func removeServer(_ server: HTTPServer) {
        activeServersLock.lock()
        activeServers.removeAll { $0 === server }
        activeServersLock.unlock()
    }

    private func findAvailablePortExcluding(_ excluded: Set<UInt16>) -> UInt16 {
        for port: UInt16 in 8080...9000 {
            if !excluded.contains(port) {
                return port
            }
        }
        return UInt16.random(in: 9001...65535)
    }
}
