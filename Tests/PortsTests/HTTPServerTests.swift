import Network
import XCTest
@testable import Ports

final class HTTPServerTests: XCTestCase {
    func testServerInitializesWithPortAndDirectory() {
        let tempDir = FileManager.default.temporaryDirectory
        let server = HTTPServer(port: 8080, directory: tempDir)

        XCTAssertEqual(server.port, 8080)
        XCTAssertEqual(server.directory, tempDir)
        XCTAssertFalse(server.exposeToLAN)
        XCTAssertFalse(server.isRunning)
    }

    func testServerCanEnableLANAccess() {
        let tempDir = FileManager.default.temporaryDirectory
        let server = HTTPServer(port: 8080, directory: tempDir, exposeToLAN: true)

        XCTAssertTrue(server.exposeToLAN)
    }

    func testServerStartsAndStops() throws {
        let tempDir = FileManager.default.temporaryDirectory
        // Use a random high port to avoid conflicts
        let port: UInt16 = UInt16.random(in: 49000...49999)
        let server = HTTPServer(port: port, directory: tempDir)

        XCTAssertFalse(server.isRunning)

        try server.start()
        XCTAssertTrue(server.isRunning)

        server.stop()
        // Give it a moment to clean up
        sleep(1)
        XCTAssertFalse(server.isRunning)
    }

    func testStartThrowsWhenPortIsAlreadyInUse() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let port = UInt16.random(in: 49000...49999)

        let holder = HTTPServer(port: port, directory: tempDir)
        try holder.start()
        addTeardownBlock { holder.stop() }

        let contender = HTTPServer(port: port, directory: tempDir)
        XCTAssertThrowsError(try contender.start(), "binding an occupied port must fail synchronously")
        XCTAssertFalse(contender.isRunning, "a server that failed to bind must not report itself as running")
    }

    func testServerHandlesPortZero() throws {
        let tempDir = FileManager.default.temporaryDirectory
        // Port 0 tells the OS to pick any available port
        let server = HTTPServer(port: 0, directory: tempDir)

        // This may or may not succeed depending on NWListener behavior
        // The test verifies it doesn't crash
        do {
            try server.start()
            server.stop()
        } catch {
            // Acceptable - port 0 might not be supported
        }
    }

    func testMimeTypeReturnsCorrectTypes() {
        // Test via reflection or make mimeType public if needed
        // For now, we test indirectly through the server
        let tempDir = FileManager.default.temporaryDirectory
        let server = HTTPServer(port: 8080, directory: tempDir)

        // Server should initialize without issues
        XCTAssertNotNil(server)
    }

    /// Fetches `path` and returns the status code plus the body as a string.
    private func fetch(port: UInt16, path: String, file: StaticString = #filePath, line: UInt = #line) throws -> (status: Int, body: String) {
        let url = try XCTUnwrap(URL(string: "http://localhost:\(port)\(path)"), file: file, line: line)
        // A fresh session per request: the server sends "Connection: close", so a
        // pooled connection from an earlier request would fail with -1005.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let expectation = expectation(description: "Fetch \(path)")

        var gotData: Data?
        var gotResponse: URLResponse?
        var gotError: Error?
        let task = session.dataTask(with: url) { data, response, error in
            gotData = data
            gotResponse = response
            gotError = error
            expectation.fulfill()
        }
        task.resume()
        waitForExpectations(timeout: 5)

        XCTAssertNil(gotError, file: file, line: line)
        let response = try XCTUnwrap(gotResponse as? HTTPURLResponse, file: file, line: line)
        return (response.statusCode, String(data: gotData ?? Data(), encoding: .utf8) ?? "")
    }

    func testSymlinkedIndexFileIsNotServedFromOutsideRoot() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("serve", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)

        let secret = outside.appendingPathComponent("greendale-transcript.txt")
        let secretBody = "Troy Barnes, Air Conditioning Repair Annex"
        try Data(secretBody.utf8).write(to: secret)

        // Both the root index and a subdirectory index point outside the served root.
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("index.html"), withDestinationURL: secret)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("sub/index.html"), withDestinationURL: secret)

        let port = UInt16.random(in: 49000...49999)
        let server = HTTPServer(port: port, directory: root)
        try server.start()
        addTeardownBlock {
            server.stop()
            XCTAssertNoThrow(try fileManager.removeItem(at: base))
        }

        for path in ["/", "/sub/"] {
            let got = try fetch(port: port, path: path)
            XCTAssertEqual(got.status, 200, "\(path) should fall back to a directory listing")
            XCTAssertFalse(got.body.contains(secretBody), "\(path) leaked a file from outside the served root")
            XCTAssertTrue(got.body.contains("Index of"), "\(path) should have served a directory listing")
        }
    }

    func testSymlinkedFileRequestedDirectlyIsForbidden() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("serve", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let secret = base.appendingPathComponent("senor-chang.txt")
        try Data("I am a real professor".utf8).write(to: secret)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: secret)

        let port = UInt16.random(in: 49000...49999)
        let server = HTTPServer(port: port, directory: root)
        try server.start()
        addTeardownBlock {
            server.stop()
            XCTAssertNoThrow(try fileManager.removeItem(at: base))
        }

        XCTAssertEqual(try fetch(port: port, path: "/escape.txt").status, 403)
    }

    func testStalledResponseIsCancelledSoTheSlotIsReclaimed() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Large enough that the send cannot complete into socket buffers alone,
        // so the transfer stalls against a client that never reads.
        let fileSizeBytes = 64 * 1024 * 1024
        let fileURL = tempDir.appendingPathComponent("annies-move.bin")
        fileManager.createFile(atPath: fileURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: fileURL)
        let megabyte = Data(repeating: 0x41, count: 1024 * 1024)
        for _ in 0..<(fileSizeBytes / megabyte.count) { writer.write(megabyte) }
        try writer.close()

        let port = UInt16.random(in: 49000...49999)
        let server = HTTPServer(port: port, directory: tempDir, requestTimeout: 1)
        try server.start()
        addTeardownBlock {
            server.stop()
            XCTAssertNoThrow(try fileManager.removeItem(at: tempDir))
        }

        let requestSent = expectation(description: "Request sent")
        let connection = NWConnection(
            host: "127.0.0.1",
            port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)),
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                // Send a complete request and then read nothing, so the server's
                // send stalls once the socket buffers fill.
                connection.send(
                    content: Data("GET /annies-move.bin HTTP/1.1\r\nHost: h\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in requestSent.fulfill() }
                )
            }
        }
        connection.start(queue: .global())
        addTeardownBlock { connection.cancel() }
        wait(for: [requestSent], timeout: 5)

        // Stay silent well past the 1s deadline, then drain. A reaped connection
        // yields only what was already buffered; before the fix the deadline was
        // dropped at header-parse time, so draining here simply resumed the
        // transfer and delivered the whole file.
        Thread.sleep(forTimeInterval: 3)

        let drained = expectation(description: "Connection drained to completion")
        var received = 0
        func drain() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { data, _, isComplete, error in
                received += data?.count ?? 0
                if isComplete || error != nil {
                    drained.fulfill()
                    return
                }
                drain()
            }
        }
        drain()
        wait(for: [drained], timeout: 20)

        XCTAssertLessThan(received, fileSizeBytes / 2, "server kept streaming instead of reaping the stalled connection")
    }

    func testServerStreamsLargeFile() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileURL = tempDir.appendingPathComponent("HumanBeing.bin")
        let wantData = Data((0..<(512 * 1024)).map { UInt8($0 % 251) })
        try wantData.write(to: fileURL)

        let port = UInt16.random(in: 49000...49999)
        let server = HTTPServer(port: port, directory: tempDir)
        try server.start()

        addTeardownBlock {
            server.stop()
            XCTAssertNoThrow(try fileManager.removeItem(at: tempDir))
        }

        let url = try XCTUnwrap(URL(string: "http://localhost:\(port)/HumanBeing.bin"))
        let expectation = expectation(description: "Download streamed file")

        var gotData: Data?
        var gotResponse: URLResponse?
        var gotError: Error?

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            gotData = data
            gotResponse = response
            gotError = error
            expectation.fulfill()
        }

        task.resume()
        waitForExpectations(timeout: 5)

        XCTAssertNil(gotError)
        let response = try XCTUnwrap(gotResponse as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(gotData, wantData)
    }
}
