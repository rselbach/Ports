import Foundation
import Darwin
import os

struct PortInfo: Hashable {
    let port: UInt16
    let pid: Int32
    let processName: String
    let address: String
}

class PortScanner {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.ports",
        category: "PortScanner"
    )

    private var cachedResults: [PortInfo] = []
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 2.0
    private let cacheLock = NSLock()

    /// Returns cached port scan results if still valid, otherwise performs a fresh scan.
    /// Cache is valid for 2 seconds by default.
    func scan() -> [PortInfo] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let timestamp = cacheTimestamp {
            let elapsed = Date().timeIntervalSince(timestamp)
            if elapsed < cacheTTL {
                return cachedResults
            }
        }

        let lsofOutput = runLsof()
        cachedResults = parseLsofOutput(lsofOutput)
        cacheTimestamp = Date()
        return cachedResults
    }

    /// Forces a fresh scan, bypassing the cache.
    func forceScan() -> [PortInfo] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let lsofOutput = runLsof()
        cachedResults = parseLsofOutput(lsofOutput)
        cacheTimestamp = Date()
        return cachedResults
    }

    private func runLsof() -> String {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P", "-Fpcn", "-c0"]
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run lsof: \(error.localizedDescription, privacy: .public)")
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let terminationStatus = process.terminationStatus
        if terminationStatus != 0 && output.isEmpty {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown error"
            logger.error("lsof exited with status \(terminationStatus): \(errorMessage, privacy: .public)")
            return ""
        }

        if terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "unknown error"
            logger.notice("lsof exited with status \(terminationStatus): \(errorMessage, privacy: .public)")
        }

        return output
    }

    private func parseLsofOutput(_ output: String) -> [PortInfo] {
        var ports: [PortInfo] = []
        var seen = Set<UInt16>()
        var currentPid: Int32?
        var currentCommand: String?

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                currentPid = Int32(value)
                currentCommand = nil
            case "c":
                currentCommand = value
            case "n":
                guard let pid = currentPid else { continue }
                guard let portInfo = parseNameField(value, pid: pid, processName: currentCommand ?? "unknown") else {
                    continue
                }
                guard !seen.contains(portInfo.port) else { continue }
                seen.insert(portInfo.port)
                ports.append(portInfo)
            default:
                continue
            }
        }

        return ports
    }

    private func parseNameField(_ nameField: String, pid: Int32, processName: String) -> PortInfo? {
        let trimmed = nameField.trimmingCharacters(in: .whitespaces)
        guard let lastColon = trimmed.lastIndex(of: ":") else { return nil }

        let portString = String(trimmed[trimmed.index(after: lastColon)...]).trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(portString) else { return nil }

        let address = String(trimmed[..<lastColon]).trimmingCharacters(in: .whitespaces)

        return PortInfo(
            port: port,
            pid: pid,
            processName: processName.isEmpty ? "unknown" : processName,
            address: address
        )
    }
}
