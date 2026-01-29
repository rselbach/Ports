import Foundation
import Network

protocol HTTPServerDelegate: AnyObject {
    func server(_ server: HTTPServer, didFailWithError error: Error)
}

class HTTPServer {
    let port: UInt16
    let directory: URL
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let maxConnections = 50
    private let connectionsLock = NSLock()
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
        
        listener?.start(queue: .main)
    }
    
    func stop() {
        connectionsLock.lock()
        connections.forEach { $0.cancel() }
        connections.removeAll()
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

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connectionsLock.lock()
                self?.connections.removeAll { $0 === connection }
                self?.connectionsLock.unlock()
            }
        }
        
        connection.start(queue: .main)
        receiveRequest(connection)
    }
    
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }
            
            if let request = String(data: data, encoding: .utf8) {
                self.handleRequest(request, connection: connection)
            } else {
                connection.cancel()
            }
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
        
        var path = String(parts[1])
        path = path.removingPercentEncoding ?? path
        
        // Prevent path traversal by checking if resolved path stays within root
        let filePath = directory.appendingPathComponent(path).standardizedFileURL
        let rootDir = directory.resolvingSymlinksInPath().standardizedFileURL
        guard filePath.path.hasPrefix(rootDir.path) else {
            sendError(connection, status: 403, message: "Forbidden")
            return
        }
        
        if path == "/" {
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
                let requestPath = String(parts[1])
                if !requestPath.hasSuffix("/") {
                    sendRedirect(to: requestPath + "/", connection: connection)
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
        } else if path == "/index.html" {
            serveDirectoryListing(directory, requestPath: "/", connection: connection)
        } else {
            sendError(connection, status: 404, message: "Not Found")
        }
    }
    
    private func serveFile(_ url: URL, connection: NWConnection) {
        guard let data = try? Data(contentsOf: url) else {
            sendError(connection, status: 500, message: "Internal Server Error")
            return
        }
        
        let mimeType = mimeType(for: url.pathExtension)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: \(mimeType)\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r
        
        """
        
        var responseData = response.data(using: .utf8)!
        responseData.append(data)
        
        sendResponse(responseData, connection: connection)
    }
    
    private func serveDirectoryListing(_ dir: URL, requestPath: String, connection: NWConnection) {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Index of \(requestPath)</title>
            <style>
                body { font-family: -apple-system, sans-serif; padding: 20px; }
                a { text-decoration: none; color: #007aff; }
                a:hover { text-decoration: underline; }
                li { padding: 4px 0; }
            </style>
        </head>
        <body>
            <h1>Index of \(requestPath)</h1>
            <ul>
        """
        
        if requestPath != "/" {
            let parent = (requestPath as NSString).deletingLastPathComponent
            html += "<li><a href=\"\(parent.isEmpty ? "/" : parent)\">../</a></li>\n"
        }
        
        if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let displayName = isDir ? "\(name)/" : name
                let linkPath = requestPath.hasSuffix("/") ? "\(requestPath)\(name)" : "\(requestPath)/\(name)"
                html += "<li><a href=\"\(linkPath)\">\(displayName)</a></li>\n"
            }
        }
        
        html += """
            </ul>
        </body>
        </html>
        """
        
        let data = html.data(using: .utf8)!
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r
        
        """
        
        var responseData = response.data(using: .utf8)!
        responseData.append(data)
        
        sendResponse(responseData, connection: connection)
    }
    
    private func sendError(_ connection: NWConnection, status: Int, message: String) {
        let body = "<html><body><h1>\(status) \(message)</h1></body></html>"
        let bodyData = body.data(using: .utf8)!
        let response = """
        HTTP/1.1 \(status) \(message)\r
        Content-Type: text/html\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r
        \(body)
        """
        
        sendResponse(response.data(using: .utf8)!, connection: connection)
    }
    
    private func sendResponse(_ data: Data, connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendRedirect(to location: String, connection: NWConnection) {
        let response = """
        HTTP/1.1 301 Moved Permanently\r
        Location: \(location)\r
        Content-Length: 0\r
        Connection: close\r
        \r
        
        """
        sendResponse(response.data(using: .utf8)!, connection: connection)
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
}
