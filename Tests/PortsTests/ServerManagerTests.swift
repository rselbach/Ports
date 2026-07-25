import XCTest
@testable import Ports

final class ServerManagerTests: XCTestCase {
    private let savedServersKey = "savedServers"
    private var tempRoot: URL!
    private var originalPersistServers: Bool!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        originalPersistServers = AppSettings.shared.persistServers
        AppSettings.shared.persistServers = true
    }

    override func tearDownWithError() throws {
        AppSettings.shared.persistServers = originalPersistServers
        UserDefaults.standard.removeObject(forKey: savedServersKey)
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func persist(_ entries: [SavedServer]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: savedServersKey)
    }

    private func persisted() throws -> [SavedServer] {
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: savedServersKey))
        return try JSONDecoder().decode([SavedServer].self, from: data)
    }

    func testRestoreKeepsEntriesWhoseDirectoryIsUnavailable() throws {
        let available = tempRoot.appendingPathComponent("AlwaysHere", isDirectory: true)
        try FileManager.default.createDirectory(at: available, withIntermediateDirectories: true)
        // Never created: stands in for a folder on a volume that is not mounted.
        let unmounted = tempRoot.appendingPathComponent("ExternalDrive/Shared", isDirectory: true)

        let availablePort = UInt16.random(in: 49000...49499)
        let unmountedPort = UInt16.random(in: 49500...49999)
        try persist([
            SavedServer(port: availablePort, directoryPath: available.path, exposeToLAN: false),
            SavedServer(port: unmountedPort, directoryPath: unmounted.path, exposeToLAN: false),
        ])

        let manager = ServerManager(portScanner: PortScanner())
        _ = manager.restoreServers()
        addTeardownBlock { manager.stopAllServers() }

        let got = try persisted()
        XCTAssertEqual(got.count, 2, "an entry whose directory is unavailable must not be dropped")
        XCTAssertTrue(got.contains { $0.directoryPath == unmounted.path && $0.port == unmountedPort })

        // A later save, such as the one after stopping a server, must not drop it either.
        manager.saveServers()
        XCTAssertTrue(try persisted().contains { $0.directoryPath == unmounted.path })
    }

    func testRestoreKeepsTheConfiguredPortWhenItIsBusy() throws {
        let directory = tempRoot.appendingPathComponent("Study Room F", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuredPort = UInt16.random(in: 49000...49999)
        let squatter = HTTPServer(port: configuredPort, directory: directory)
        try squatter.start()
        addTeardownBlock { squatter.stop() }

        try persist([SavedServer(port: configuredPort, directoryPath: directory.path, exposeToLAN: false)])

        let manager = ServerManager(portScanner: PortScanner())
        _ = manager.restoreServers()
        addTeardownBlock { manager.stopAllServers() }

        let got = try persisted()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].port, configuredPort, "the user's chosen port must survive a busy port at launch")
    }

    func testStoppingAServerRemovesOnlyThatEntry() throws {
        let first = tempRoot.appendingPathComponent("Greendale", isDirectory: true)
        let second = tempRoot.appendingPathComponent("Blorgons", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let manager = ServerManager(portScanner: PortScanner())
        addTeardownBlock { manager.stopAllServers() }
        try manager.startServer(port: UInt16.random(in: 49000...49499), directory: first, exposeToLAN: false)
        try manager.startServer(port: UInt16.random(in: 49500...49999), directory: second, exposeToLAN: false)
        XCTAssertEqual(try persisted().count, 2)

        let toStop = try XCTUnwrap(manager.snapshotServers().first { $0.directory.path == first.path })
        manager.stopServer(toStop)

        let got = try persisted()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].directoryPath, second.path)
    }
}
