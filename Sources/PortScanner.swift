import Foundation
import Darwin

struct PortInfo: Hashable {
    let port: UInt16
    let pid: Int32
    let processName: String
    let address: String
}

class PortScanner {
    func scan() -> [PortInfo] {
        let lsofOutput = runLsof()
        return parseLsofOutput(lsofOutput)
    }

    private func runLsof() -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P", "-c0"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseLsofOutput(_ output: String) -> [PortInfo] {
        var ports: [PortInfo] = []
        var seen = Set<UInt16>()

        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("COMMAND") else { continue }
            
            // Split line on whitespace
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }

            // PID is in column 2 (index 1)
            guard let pid = Int32(parts[1]) else { continue }

            // NAME field is the last column (index 8 or later if command has spaces)
            // Find the column containing ":port" pattern with LISTEN state
            let nameField = String(parts[8...].joined(separator: " "))
            
            // Parse address:port from NAME field
            // Format: "127.0.0.1:8080 (LISTEN)" or "*:8080 (LISTEN)" or "[::]:8080 (LISTEN)"
            // Handle IPv6 by finding the LAST colon before the parenthesis
            guard let parenStart = nameField.firstIndex(of: "("),
                  let lastColon = nameField[..<parenStart].lastIndex(of: ":") else { continue }

            let portString = String(nameField[nameField.index(after: lastColon)..<parenStart])
                .trimmingCharacters(in: .whitespaces)
            guard let port = UInt16(portString) else { continue }

            guard !seen.contains(port) else { continue }
            seen.insert(port)

            let address = String(nameField[..<lastColon]).trimmingCharacters(in: .whitespaces)
            let processName = getProcessName(pid: pid)

            ports.append(PortInfo(
                port: port,
                pid: pid,
                processName: processName,
                address: address
            ))
        }

        return ports
    }

    private func getProcessName(pid: Int32) -> String {
        // Guard against invalid PIDs
        guard pid > 0 else { return "invalid" }
        
        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { nameBuffer.deallocate() }
        
        // Clear buffer to ensure null termination
        nameBuffer.initialize(repeating: 0, count: Int(MAXPATHLEN))
        
        let length = proc_name(pid, nameBuffer, UInt32(MAXPATHLEN))
        if length > 0 {
            let name = String(cString: nameBuffer)
            // Validate the name isn't empty or just whitespace
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "unknown" : name
        }
        return "unknown"
    }
}
