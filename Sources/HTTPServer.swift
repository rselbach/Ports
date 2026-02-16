import Foundation
import Network
import os

enum HTTPUtilities {
    static func htmlEscaped(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        return escaped
    }

    static func percentEncodedPath(_ path: String) -> String {
        var components = URLComponents()
        components.path = path
        let encodedPath = components.percentEncodedPath
        if encodedPath.isEmpty {
            return "/"
        }
        return encodedPath
    }

    /// Sanitizes a header value to prevent CRLF injection.
    /// Removes any carriage returns, line feeds, and null bytes.
    static func sanitizedHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\0", with: "")
    }
}

protocol HTTPServerDelegate: AnyObject {
    func server(_ server: HTTPServer, didFailWithError error: Error)
}

class HTTPServer {
    let port: UInt16
    let directory: URL
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private let maxConnections = 50
    private let maxRequestHeaderBytes = 64 * 1024
    private let requestTimeout: TimeInterval = 30
    private let connectionsLock = NSLock()
    private let serverQueue = DispatchQueue(label: "com.rselbach.ports.httpserver", qos: .userInitiated, attributes: .concurrent)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.ports",
        category: "HTTPServer"
    )
    weak var delegate: HTTPServerDelegate?
    
    var isRunning: Bool { listener != nil }
    
    init(port: UInt16, directory: URL) {
        self.port = port
        self.directory = directory
    }
    
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "HTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"])
        }
        listener = try NWListener(using: params, on: endpointPort)
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed(let error):
                self.delegate?.server(self, didFailWithError: error)
            case .cancelled:
                self.connectionsLock.lock()
                self.connections.removeAll { $0.state == .cancelled }
                self.connectionsLock.unlock()
            default:
                break
            }
        }
        
        listener?.start(queue: serverQueue)
    }
    
    func stop() {
        connectionsLock.lock()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        connectionTimeouts.values.forEach { $0.cancel() }
        connectionTimeouts.removeAll()
        connectionsLock.unlock()
        listener?.cancel()
        listener = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        guard connections.count < maxConnections else {
            connectionsLock.unlock()
            sendError(connection, status: 503, message: "Service Unavailable - Too many connections")
            connection.cancel()
            return
        }
        connections.append(connection)
        connectionsLock.unlock()

        let connectionId = ObjectIdentifier(connection)
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.logger.debug("Connection timeout on port \(self.port)")
            self.cancelConnectionTimeout(connectionId)
            connection.cancel()
        }
        connectionsLock.lock()
        connectionTimeouts[connectionId] = timeoutWorkItem
        connectionsLock.unlock()
        serverQueue.asyncAfter(deadline: .now() + requestTimeout, execute: timeoutWorkItem)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .cancelled = state {
                self.cancelConnectionTimeout(connectionId)
                self.connectionsLock.lock()
                self.connections.removeAll { $0 === connection }
                self.connectionsLock.unlock()
            }
        }

        connection.start(queue: serverQueue)
        receiveRequest(connection)
    }

    private func cancelConnectionTimeout(_ connectionId: ObjectIdentifier) {
        connectionsLock.lock()
        if let workItem = connectionTimeouts.removeValue(forKey: connectionId) {
            workItem.cancel()
        }
        connectionsLock.unlock()
    }
    
    private func receiveRequest(_ connection: NWConnection, buffer: Data = Data()) {
        let connectionId = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            if let error {
                self.logger.error("Receive failed on port \(self.port): \(error.localizedDescription, privacy: .public)")
                self.cancelConnectionTimeout(connectionId)
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if accumulated.count > self.maxRequestHeaderBytes {
                self.cancelConnectionTimeout(connectionId)
                self.sendError(connection, status: 413, message: "Request Entity Too Large")
                return
            }

            if let headerEndRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = accumulated.subdata(in: accumulated.startIndex..<headerEndRange.upperBound)
                guard let request = String(data: headerData, encoding: .utf8) else {
                    self.cancelConnectionTimeout(connectionId)
                    self.sendError(connection, status: 400, message: "Bad Request")
                    return
                }
                self.cancelConnectionTimeout(connectionId)
                self.handleRequest(request, connection: connection)
                return
            }

            if isComplete {
                self.cancelConnectionTimeout(connectionId)
                self.sendError(connection, status: 400, message: "Bad Request")
                return
            }

            self.receiveRequest(connection, buffer: accumulated)
        }
    }
    
    private func handleRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(connection, status: 400, message: "Bad Request")
            return
        }
        
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendError(connection, status: 405, message: "Method Not Allowed")
            return
        }
        
        let rawPath = String(parts[1])
        let (requestPath, relativePath) = normalizedRequestPath(rawPath)
        
        // Prevent path traversal by checking if resolved path stays within root
        let filePath = directory.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        let rootDir = directory.resolvingSymlinksInPath().standardizedFileURL
        guard isPath(filePath, inside: rootDir) else {
            sendError(connection, status: 403, message: "Forbidden")
            return
        }
        
        if requestPath == "/" {
            let indexPath = directory.appendingPathComponent("index.html")
            if !FileManager.default.fileExists(atPath: indexPath.path) {
                // No index.html, serve directory listing
                serveDirectoryListing(directory, requestPath: "/", connection: connection)
                return
            }
        }
        
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: filePath.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                if !requestPath.hasSuffix("/") {
                    let redirectPath = HTTPUtilities.percentEncodedPath(requestPath + "/")
                    sendRedirect(to: redirectPath, connection: connection)
                    return
                }
                if let indexFile = findIndexFile(in: filePath) {
                    serveFile(indexFile, connection: connection)
                } else {
                    serveDirectoryListing(filePath, requestPath: requestPath, connection: connection)
                }
            } else {
                serveFile(filePath, connection: connection)
            }
        } else if requestPath == "/index.html" {
            serveDirectoryListing(directory, requestPath: "/", connection: connection)
        } else {
            sendError(connection, status: 404, message: "Not Found")
        }
    }
    
    private func serveFile(_ url: URL, connection: NWConnection) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("Failed to read file \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            sendError(connection, status: 500, message: "Internal Server Error")
            return
        }

        let mimeType = mimeType(for: url.pathExtension)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: \(mimeType)\r
        Content-Length: \(data.count)\r
        Connection: close\r
        X-Content-Type-Options: nosniff\r
        \r

        """

        var responseData = Data(response.utf8)
        responseData.append(data)

        sendResponse(responseData, connection: connection)
    }
    
    private func serveDirectoryListing(_ dir: URL, requestPath: String, connection: NWConnection) {
        let safeRequestPath = HTTPUtilities.htmlEscaped(requestPath)
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Index of \(safeRequestPath)</title>
            <style>
                body { font-family: -apple-system, sans-serif; padding: 20px; }
                a { text-decoration: none; color: #007aff; }
                a:hover { text-decoration: underline; }
                li { padding: 4px 0; }
            </style>
        </head>
        <body>
            <h1>Index of \(safeRequestPath)</h1>
            <ul>
        """
        
        if requestPath != "/" {
            let parent = (requestPath as NSString).deletingLastPathComponent
            let parentPath = parent.isEmpty ? "/" : parent
            let parentHref = HTTPUtilities.htmlEscaped(HTTPUtilities.percentEncodedPath(parentPath))
            html += "<li><a href=\"\(parentHref)\">../</a></li>\n"
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                let values = try item.resourceValues(forKeys: [.isDirectoryKey])
                let isDir = values.isDirectory ?? false
                let displayName = isDir ? "\(name)/" : name
                let linkPath = requestPath.hasSuffix("/")
                    ? "\(requestPath)\(name)"
                    : "\(requestPath)/\(name)"
                let linkHref = HTTPUtilities.htmlEscaped(HTTPUtilities.percentEncodedPath(linkPath))
                let safeDisplayName = HTTPUtilities.htmlEscaped(displayName)
                html += "<li><a href=\"\(linkHref)\">\(safeDisplayName)</a></li>\n"
            }
        } catch {
            logger.error("Failed to read directory \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            sendError(connection, status: 500, message: "Internal Server Error")
            return
        }
        
        html += """
            </ul>
        </body>
        </html>
        """

        let data = Data(html.utf8)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(data.count)\r
        Connection: close\r
        X-Content-Type-Options: nosniff\r
        X-Frame-Options: DENY\r
        \r

        """

        var responseData = Data(response.utf8)
        responseData.append(data)

        sendResponse(responseData, connection: connection)
    }
    
    private func sendError(_ connection: NWConnection, status: Int, message: String) {
        let safeMessage = HTTPUtilities.htmlEscaped(message)
        let body = "<html><body><h1>\(status) \(safeMessage)</h1></body></html>"
        let bodyData = Data(body.utf8)
        let response = """
        HTTP/1.1 \(status) \(safeMessage)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        X-Content-Type-Options: nosniff\r
        X-Frame-Options: DENY\r
        \r
        \(body)
        """

        sendResponse(Data(response.utf8), connection: connection)
    }
    
    private func sendResponse(_ data: Data, connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendRedirect(to location: String, connection: NWConnection) {
        let safeLocation = HTTPUtilities.sanitizedHeaderValue(location)
        let response = """
        HTTP/1.1 301 Moved Permanently\r
        Location: \(safeLocation)\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
        sendResponse(Data(response.utf8), connection: connection)
    }
    
    private func findIndexFile(in dir: URL) -> URL? {
        let indexFiles = ["index.html", "index.htm"]
        for filename in indexFiles {
            let candidate = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
    
    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain; charset=utf-8"
        case "md": return "text/markdown; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    private func normalizedRequestPath(_ rawPath: String) -> (requestPath: String, relativePath: String) {
        let pathPart = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let fragmentPart = pathPart.first?.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let cleaned = fragmentPart?.first.map(String.init) ?? rawPath
        let decoded = cleaned.removingPercentEncoding ?? cleaned
        let requestPath = decoded.isEmpty ? "/" : decoded
        let relativePath = requestPath == "/" ? "" : requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (requestPath, relativePath)
    }

    private func isPath(_ path: URL, inside root: URL) -> Bool {
        let rootPath = root.path
        let filePath = path.path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }
}
