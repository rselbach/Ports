import AppKit
import Sparkle
import SwiftUI

struct SavedServer: Codable {
    let port: UInt16
    let directoryPath: String
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var portScanner = PortScanner()
    private var refreshTimer: Timer?
    private var statusMenu: NSMenu!
    private var activeServers: [HTTPServer] = []
    private var folderPathField: NSTextField?
    private var selectedDirectory: URL?
    private var portField: NSTextField?
    private var portWarningLabel: NSTextField?
    private var updaterController: SPUStandardUpdaterController?
    private var preferencesWindow: NSWindow?
    
    private let savedServersKey = "savedServers"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.shared
        
        if let frameworksPath = Bundle.main.privateFrameworksPath,
           FileManager.default.fileExists(atPath: "\(frameworksPath)/Sparkle.framework") {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: settings.checkForUpdates,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        setupMenuBar()
        if settings.persistServers {
            restoreServers()
        }
        startAutoRefresh()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Ports")
        }

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        rebuildMenuItems()
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenuItems()
    }

    private var menuIsOpen = false
    
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateMenu()
        }
    }
    
    private func updateMenu() {
        guard menuIsOpen else { return }
        rebuildMenuItems()
    }
    
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenuItems() {
        let menu = statusMenu!
        menu.removeAllItems()

        let scannedPorts = portScanner.scan()
        let serverPorts = Set(activeServers.map { $0.port })
        let externalPorts = scannedPorts.filter { !serverPorts.contains($0.port) }
        
        let allPorts: [(port: UInt16, isServer: Bool)] = 
            externalPorts.map { ($0.port, false) } + 
            activeServers.map { ($0.port, true) }
        let sortedPorts = allPorts.sorted { $0.port < $1.port }

        if sortedPorts.isEmpty {
            let item = NSMenuItem(title: "No listening ports found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let headerItem = NSMenuItem(title: "Port → Process", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            menu.addItem(NSMenuItem.separator())

            for entry in sortedPorts {
                if entry.isServer, let server = activeServers.first(where: { $0.port == entry.port }) {
                    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    item.attributedTitle = formatServerEntry(server)
                    item.submenu = createServerSubmenu(for: server)
                    menu.addItem(item)
                } else if let portInfo = externalPorts.first(where: { $0.port == entry.port }) {
                    let item = NSMenuItem(title: "", action: #selector(copyPort(_:)), keyEquivalent: "")
                    item.attributedTitle = formatPortEntry(portInfo)
                    item.target = self
                    item.representedObject = portInfo.port
                    menu.addItem(item)
                }
            }
        }

        menu.addItem(NSMenuItem.separator())

        let serveItem = NSMenuItem(title: "Serve Directory…", action: #selector(serveDirectory), keyEquivalent: "s")
        serveItem.target = self
        menu.addItem(serveItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        if let updater = updaterController {
            let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "u")
            updateItem.target = updater
            menu.addItem(updateItem)
        }
        
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func formatPortEntry(_ port: PortInfo) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let portColor = NSColor.systemCyan
        let arrowColor = NSColor.secondaryLabelColor
        let processColor = NSColor.systemGreen
        let pidColor = NSColor.tertiaryLabelColor

        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let regular = NSFont.menuFont(ofSize: 13)

        let portStr = String(format: "%5d", port.port)
        result.append(NSAttributedString(string: portStr, attributes: [
            .foregroundColor: portColor,
            .font: mono
        ]))

        result.append(NSAttributedString(string: " → ", attributes: [
            .foregroundColor: arrowColor,
            .font: regular
        ]))

        result.append(NSAttributedString(string: port.processName, attributes: [
            .foregroundColor: processColor,
            .font: regular
        ]))

        result.append(NSAttributedString(string: " (pid \(port.pid))", attributes: [
            .foregroundColor: pidColor,
            .font: regular
        ]))

        return result
    }
    
    private func formatServerEntry(_ server: HTTPServer) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let portColor = NSColor.systemCyan
        let arrowColor = NSColor.secondaryLabelColor
        let processColor = NSColor.systemOrange
        let pathColor = NSColor.tertiaryLabelColor

        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let regular = NSFont.menuFont(ofSize: 13)

        let portStr = String(format: "%5d", server.port)
        result.append(NSAttributedString(string: portStr, attributes: [
            .foregroundColor: portColor,
            .font: mono
        ]))

        result.append(NSAttributedString(string: " → ", attributes: [
            .foregroundColor: arrowColor,
            .font: regular
        ]))

        result.append(NSAttributedString(string: server.directory.lastPathComponent, attributes: [
            .foregroundColor: processColor,
            .font: regular
        ]))

        result.append(NSAttributedString(string: " (server)", attributes: [
            .foregroundColor: pathColor,
            .font: regular
        ]))

        return result
    }

    @objc private func copyPort(_ sender: NSMenuItem) {
        if let port = sender.representedObject as? UInt16 {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(port), forType: .string)
        }
    }

    @objc private func refreshNow() {
        updateMenu()
    }

    @objc private func quit() {
        activeServers.forEach { $0.stop() }
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func openPreferences() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ports Preferences"
        window.center()
        window.contentView = NSHostingView(rootView: PreferencesView())
        window.isReleasedWhenClosed = false
        window.delegate = self
        preferencesWindow = window
        
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === preferencesWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func createServerSubmenu(for server: HTTPServer) -> NSMenu {
        let submenu = NSMenu()

        let urlItem = NSMenuItem(title: "http://localhost:\(server.port)", action: #selector(openServerURL(_:)), keyEquivalent: "")
        urlItem.target = self
        urlItem.representedObject = server
        submenu.addItem(urlItem)

        let copyItem = NSMenuItem(title: "Copy URL", action: #selector(copyServerURL(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = server
        submenu.addItem(copyItem)

        submenu.addItem(NSMenuItem.separator())

        let stopItem = NSMenuItem(title: "Stop Server", action: #selector(stopServer(_:)), keyEquivalent: "")
        stopItem.target = self
        stopItem.representedObject = server
        submenu.addItem(stopItem)

        return submenu
    }

    @objc private func serveDirectory() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            self.showServeDialog()

            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showServeDialog() {
        selectedDirectory = nil

        let alert = NSAlert()
        alert.messageText = "Serve Directory"
        alert.informativeText = "Select a folder and port to start the HTTP server."
        alert.addButton(withTitle: "Start Server")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 70))

        let folderLabel = NSTextField(labelWithString: "Folder:")
        folderLabel.frame = NSRect(x: 0, y: 44, width: 50, height: 20)
        container.addSubview(folderLabel)

        let folderPath = NSTextField(frame: NSRect(x: 55, y: 42, width: 210, height: 24))
        folderPath.placeholderString = "/path/to/folder"
        folderPath.lineBreakMode = .byTruncatingMiddle
        container.addSubview(folderPath)
        folderPathField = folderPath

        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolderAction))
        chooseButton.frame = NSRect(x: 270, y: 40, width: 80, height: 28)
        container.addSubview(chooseButton)

        let portLabel = NSTextField(labelWithString: "Port:")
        portLabel.frame = NSRect(x: 0, y: 8, width: 50, height: 20)
        container.addSubview(portLabel)

        let portInput = NSTextField(frame: NSRect(x: 55, y: 6, width: 80, height: 24))
        portInput.stringValue = String(findAvailablePort())
        container.addSubview(portInput)
        portField = portInput

        let warningLabel = NSTextField(labelWithString: "")
        warningLabel.font = NSFont.systemFont(ofSize: 11)
        warningLabel.textColor = .systemRed
        warningLabel.frame = NSRect(x: 140, y: 8, width: 150, height: 18)
        warningLabel.isHidden = true
        container.addSubview(warningLabel)
        portWarningLabel = warningLabel

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(portFieldDidChange),
            name: NSControl.textDidChangeNotification,
            object: portInput
        )
        validatePort()

        alert.accessoryView = container

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let directory: URL
        if let selected = selectedDirectory {
            directory = selected
        } else {
            let typed = folderPath.stringValue.trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else {
                showError("Please select or enter a folder path.")
                return
            }
            directory = URL(fileURLWithPath: typed)
        }

        guard FileManager.default.fileExists(atPath: directory.path) else {
            showError("Folder does not exist: \(directory.path)")
            return
        }

        let portText = self.portField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let port: UInt16

        if portText.isEmpty {
            port = findAvailablePort()
        } else if let p = UInt16(portText), p >= 1024 {
            port = p
        } else {
            showError("Invalid port number. Must be 1024-65535.")
            return
        }

        startServer(port: port, directory: directory)
    }

    @objc private func chooseFolderAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory to serve"

        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url
            folderPathField?.stringValue = url.path
        }
    }

    @objc private func portFieldDidChange() {
        validatePort()
    }

    private func validatePort() {
        guard let portText = portField?.stringValue.trimmingCharacters(in: .whitespaces),
              !portText.isEmpty,
              let port = UInt16(portText) else {
            portField?.textColor = .labelColor
            portWarningLabel?.isHidden = true
            return
        }

        let inUse = isPortInUse(port)
        portField?.textColor = inUse ? .systemRed : .labelColor
        portWarningLabel?.stringValue = "(port in use)"
        portWarningLabel?.isHidden = !inUse
    }

    private func isPortInUse(_ port: UInt16) -> Bool {
        if activeServers.contains(where: { $0.port == port }) {
            return true
        }

        let ports = portScanner.scan()
        return ports.contains(where: { $0.port == port })
    }

    private func findAvailablePort() -> UInt16 {
        let startPort = AppSettings.shared.defaultPort
        for port in startPort...min(startPort + 100, 65535) {
            if !isPortInUse(port) {
                return port
            }
        }
        return UInt16.random(in: 8200...9000)
    }

    private func startServer(port: UInt16, directory: URL) {
        let server = HTTPServer(port: port, directory: directory)
        do {
            try server.start()
            activeServers.append(server)
            saveServers()
            updateMenu()
        } catch {
            showError("Failed to start server: \(error.localizedDescription)")
        }
    }
    
    private func saveServers() {
        guard AppSettings.shared.persistServers else {
            UserDefaults.standard.removeObject(forKey: savedServersKey)
            return
        }
        let saved = activeServers.map { SavedServer(port: $0.port, directoryPath: $0.directory.path) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: savedServersKey)
        }
    }
    
    private func restoreServers() {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey),
              let saved = try? JSONDecoder().decode([SavedServer].self, from: data) else {
            return
        }
        
        let usedPorts = Set(portScanner.scan().map { $0.port })
        var reservedPorts = Set<UInt16>()
        
        for s in saved {
            reservedPorts.insert(s.port)
        }
        
        for s in saved {
            let directory = URL(fileURLWithPath: s.directoryPath)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            
            var port = s.port
            if usedPorts.contains(port) || activeServers.contains(where: { $0.port == port }) {
                port = findAvailablePortExcluding(reservedPorts.union(usedPorts))
            }
            reservedPorts.insert(port)
            
            let server = HTTPServer(port: port, directory: directory)
            do {
                try server.start()
                activeServers.append(server)
            } catch {
                print("Failed to restore server on port \(port): \(error)")
            }
        }
        
        if !activeServers.isEmpty {
            saveServers()
            updateMenu()
        }
    }
    
    private func findAvailablePortExcluding(_ excluded: Set<UInt16>) -> UInt16 {
        for port: UInt16 in 8080...9000 {
            if !excluded.contains(port) {
                return port
            }
        }
        return UInt16.random(in: 9001...65535)
    }

    @objc private func openServerURL(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? HTTPServer else { return }
        let url = URL(string: "http://localhost:\(server.port)")!
        NSWorkspace.shared.open(url)
    }

    @objc private func copyServerURL(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? HTTPServer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://localhost:\(server.port)", forType: .string)
    }

    @objc private func stopServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? HTTPServer else { return }
        server.stop()
        activeServers.removeAll { $0 === server }
        saveServers()
        updateMenu()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

}
