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
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }

            guard let pid = Int32(parts[1]) else { continue }

            let nameField = String(parts[8])

            guard let colonIndex = nameField.lastIndex(of: ":"),
                  let port = UInt16(nameField[nameField.index(after: colonIndex)...]) else {
                continue
            }

            guard !seen.contains(port) else { continue }
            seen.insert(port)

            let address = String(nameField[..<colonIndex])
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
        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { nameBuffer.deallocate() }

        let length = proc_name(pid, nameBuffer, UInt32(MAXPATHLEN))
        if length > 0 {
            return String(cString: nameBuffer)
        }
        return "unknown"
    }
}
