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
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P", "-Fpcn", "-c0"]
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
