import Foundation
@testable import Ports

enum TestSupport {
    /// Test listen ports come from below the ephemeral range, which starts at
    /// 49152 on macOS. The kernel assigns ephemeral ports to outgoing
    /// connections, so a listener up there fails intermittently with EADDRINUSE
    /// on a machine that is doing anything else.
    static func randomPort() -> UInt16 {
        UInt16.random(in: 20000...29999)
    }

    /// Starts a server on a free port, retrying past one that was claimed
    /// between picking it and binding it.
    static func startServer(
        directory: URL,
        exposeToLAN: Bool = false,
        requestTimeout: TimeInterval = 30,
        attempts: Int = 8
    ) throws -> HTTPServer {
        var lastError: Error?
        for _ in 0..<attempts {
            let server = HTTPServer(
                port: randomPort(),
                directory: directory,
                exposeToLAN: exposeToLAN,
                requestTimeout: requestTimeout
            )
            do {
                try server.start()
                return server
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "TestSupport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not find a free port"]
        )
    }
}
