import AppKit
import Darwin
import os
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let portScanner = PortScanner()
    private lazy var serverManager = ServerManager(portScanner: portScanner)
    private var statusMenu: NSMenu!
    private var folderPathField: NSTextField?
    private var selectedDirectory: URL?
    private var portField: NSTextField?
    private var portWarningLabel: NSTextField?
    private var portObserver: NSObjectProtocol?
    private var updaterController: SPUStandardUpdaterController?
    private var preferencesWindow: NSWindow?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.ports",
        category: "AppDelegate"
    )
    
    private struct MenuEntryColors {
        let portColor: NSColor
        let arrowColor: NSColor
        let processColor: NSColor
        let detailColor: NSColor
    }

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

        serverManager.onServerFailure = { [weak self] server, error in
            guard let self else { return }
            self.logger.error("Server on port \(server.port) failed: \(error.localizedDescription, privacy: .public)")
            self.rebuildMenuItems()
        }

        setupMenuBar()
        if settings.persistServers {
            restoreServers()
            rebuildMenuItems()
        }
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
        // Force fresh scan on background queue when user opens menu
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ports = self.portScanner.forceScan()
            DispatchQueue.main.async {
                self.pendingScanResult = ports
                self.rebuildMenuItems()
            }
        }
    }

    private var pendingScanResult: [PortInfo] = []

    private func rebuildMenuItems() {
        let menu = statusMenu!
        menu.removeAllItems()

        // Use pending result from background scan, or cached result if available
        let scannedPorts = pendingScanResult.isEmpty ? portScanner.scan() : pendingScanResult
        pendingScanResult = []
        let serversSnapshot = snapshotServers()
        let serversByPort = Dictionary(uniqueKeysWithValues: serversSnapshot.map { ($0.port, $0) })
        let serverPorts = Set(serversSnapshot.map { $0.port })
        let externalPorts = scannedPorts.filter { !serverPorts.contains($0.port) }
        let externalPortsByPort = Dictionary(uniqueKeysWithValues: externalPorts.map { ($0.port, $0) })
        
        let allPorts: [(port: UInt16, isServer: Bool)] = 
            externalPorts.map { ($0.port, false) } + 
            serversSnapshot.map { ($0.port, true) }
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
                if entry.isServer, let server = serversByPort[entry.port] {
                    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    item.attributedTitle = formatServerEntry(server)
                    item.submenu = createServerSubmenu(for: server)
                    menu.addItem(item)
                } else if let portInfo = externalPortsByPort[entry.port] {
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

        // Add "Stop All Servers" if there are active servers
        let servers = snapshotServers()
        if !servers.isEmpty {
            let stopAllItem = NSMenuItem(title: "Stop All Servers (\(servers.count))", action: #selector(stopAllServers), keyEquivalent: "")
            stopAllItem.target = self
            menu.addItem(stopAllItem)
        }

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

    private func useDarkMenuColors() -> Bool {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        switch match {
        case .darkAqua:
            return true
        case .aqua:
            return false
        case .none:
            return false
        case .some:
            return false
        @unknown default:
            return false
        }
    }

    private func portEntryColors() -> MenuEntryColors {
        let useDark = useDarkMenuColors()
        switch useDark {
        case true:
            return MenuEntryColors(
                portColor: .systemCyan,
                arrowColor: .secondaryLabelColor,
                processColor: .systemGreen,
                detailColor: .tertiaryLabelColor
            )
        case false:
            return MenuEntryColors(
                portColor: NSColor(calibratedRed: 0.0, green: 0.48, blue: 0.78, alpha: 1.0),
                arrowColor: .labelColor,
                processColor: NSColor(calibratedRed: 0.0, green: 0.55, blue: 0.18, alpha: 1.0),
                detailColor: .secondaryLabelColor
            )
        }
    }

    private func serverEntryColors() -> MenuEntryColors {
        let useDark = useDarkMenuColors()
        switch useDark {
        case true:
            return MenuEntryColors(
                portColor: .systemCyan,
                arrowColor: .secondaryLabelColor,
                processColor: .systemOrange,
                detailColor: .tertiaryLabelColor
            )
        case false:
            return MenuEntryColors(
                portColor: NSColor(calibratedRed: 0.0, green: 0.48, blue: 0.78, alpha: 1.0),
                arrowColor: .labelColor,
                processColor: NSColor(calibratedRed: 0.78, green: 0.36, blue: 0.0, alpha: 1.0),
                detailColor: .secondaryLabelColor
            )
        }
    }

    private func formatPortEntry(_ port: PortInfo) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let colors = portEntryColors()
        let portColor = colors.portColor
        let arrowColor = colors.arrowColor
        let processColor = colors.processColor
        let pidColor = colors.detailColor

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

        let colors = serverEntryColors()
        let portColor = colors.portColor
        let arrowColor = colors.arrowColor
        let processColor = colors.processColor
        let pathColor = colors.detailColor

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

        let modeSymbol = accessModeSymbol(for: server)
        result.append(NSAttributedString(string: " (\(modeSymbol))", attributes: [
            .foregroundColor: pathColor,
            .font: regular
        ]))

        return result
    }

    @objc private func copyPort(_ sender: NSMenuItem) {
        if let port = sender.representedObject as? UInt16 {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(port), forType: .string)
            showCopyConfirmation()
        }
    }

    @objc private func quit() {
        let servers = snapshotServers()
        if !servers.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit Ports?"
            alert.informativeText = "\(servers.count) server(s) are still running. They will be stopped when you quit."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            if alert.runModal() == .alertFirstButtonReturn {
                serverManager.stopAllServers()
                NSApplication.shared.terminate(nil)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    @objc private func stopAllServers() {
        serverManager.stopAllServers()
        rebuildMenuItems()
    }
    
    @objc private func openPreferences() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
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

        let modeItem = NSMenuItem(title: accessModeTitle(for: server), action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        submenu.addItem(modeItem)
        submenu.addItem(NSMenuItem.separator())

        let localURL = localURLString(for: server)
        let lanURL = lanURLString(for: server)
        let localItem = NSMenuItem(title: localURL, action: #selector(openURLString(_:)), keyEquivalent: "")
        localItem.target = self
        localItem.representedObject = localURL
        submenu.addItem(localItem)

        if let lanURL {
            let lanItem = NSMenuItem(title: lanURL, action: #selector(openURLString(_:)), keyEquivalent: "")
            lanItem.target = self
            lanItem.representedObject = lanURL
            submenu.addItem(lanItem)
        } else if server.exposeToLAN {
            let unavailable = NSMenuItem(title: "LAN URL unavailable", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            submenu.addItem(unavailable)
        }

        submenu.addItem(NSMenuItem.separator())

        let copyLocalItem = NSMenuItem(title: "Copy Local URL", action: #selector(copyURLString(_:)), keyEquivalent: "")
        copyLocalItem.target = self
        copyLocalItem.representedObject = localURL
        submenu.addItem(copyLocalItem)

        if let lanURL {
            let copyLANItem = NSMenuItem(title: "Copy LAN URL", action: #selector(copyURLString(_:)), keyEquivalent: "")
            copyLANItem.target = self
            copyLANItem.representedObject = lanURL
            submenu.addItem(copyLANItem)
        }

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
        }
    }

    private func showServeDialog() {
        selectedDirectory = nil
        defer { NSApp.setActivationPolicy(.accessory) }

        let alert = NSAlert()
        alert.messageText = "Serve Directory"
        alert.informativeText = "Select a folder, a port, and whether to allow LAN access."
        alert.addButton(withTitle: "Start Server")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 110))

        let folderLabel = NSTextField(labelWithString: "Folder:")
        folderLabel.frame = NSRect(x: 0, y: 76, width: 50, height: 20)
        container.addSubview(folderLabel)

        let folderPath = NSTextField(frame: NSRect(x: 55, y: 74, width: 210, height: 24))
        folderPath.placeholderString = "/path/to/folder"
        folderPath.lineBreakMode = .byTruncatingMiddle
        container.addSubview(folderPath)
        folderPathField = folderPath

        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolderAction))
        chooseButton.frame = NSRect(x: 270, y: 72, width: 80, height: 28)
        container.addSubview(chooseButton)

        let portLabel = NSTextField(labelWithString: "Port:")
        portLabel.frame = NSRect(x: 0, y: 42, width: 50, height: 20)
        container.addSubview(portLabel)

        let portInput = NSTextField(frame: NSRect(x: 55, y: 40, width: 80, height: 24))
        portInput.stringValue = String(findAvailablePort())
        container.addSubview(portInput)
        portField = portInput

        let warningLabel = NSTextField(labelWithString: "")
        warningLabel.font = NSFont.systemFont(ofSize: 11)
        warningLabel.textColor = .systemRed
        warningLabel.frame = NSRect(x: 140, y: 42, width: 150, height: 18)
        warningLabel.isHidden = true
        container.addSubview(warningLabel)
        portWarningLabel = warningLabel

        let shareOnLANCheckbox = NSButton(checkboxWithTitle: "Allow access from other devices on this LAN", target: nil, action: nil)
        shareOnLANCheckbox.state = AppSettings.shared.shareOnLANByDefault ? .on : .off
        shareOnLANCheckbox.frame = NSRect(x: 0, y: 10, width: 350, height: 20)
        container.addSubview(shareOnLANCheckbox)

        portObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: portInput,
            queue: nil
        ) { [weak self] _ in
            self?.portFieldDidChange()
        }
        validatePort()

        alert.accessoryView = container

        let response = alert.runModal()
        if let observer = portObserver {
            NotificationCenter.default.removeObserver(observer)
            portObserver = nil
        }
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

        if isPortInUse(port) {
            showError("Port \(port) is already in use.")
            return
        }

        let exposeToLAN = shareOnLANCheckbox.state == .on
        if exposeToLAN && !confirmLANExposure(port: port, directory: directory) {
            return
        }

        startServer(port: port, directory: directory, exposeToLAN: exposeToLAN)
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

    private func portFieldDidChange() {
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
        serverManager.isPortInUse(port)
    }

    private func findAvailablePort() -> UInt16 {
        serverManager.findAvailablePort(defaultPort: AppSettings.shared.defaultPort)
    }

    private func confirmLANExposure(port: UInt16, directory: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Share folder on your local network?"
        alert.informativeText = "Any device on this LAN can access \"\(directory.lastPathComponent)\" at port \(port)."
        alert.addButton(withTitle: "Start LAN Server")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func startServer(port: UInt16, directory: URL, exposeToLAN: Bool) {
        do {
            try serverManager.startServer(port: port, directory: directory, exposeToLAN: exposeToLAN)
            rebuildMenuItems()
        } catch {
            showError("Failed to start server: \(error.localizedDescription)")
        }
    }
    
    private func restoreServers() {
        let restoredLANServers = serverManager.restoreServers()

        if !restoredLANServers.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.showRestoredLANWarning(for: restoredLANServers)
            }
        }
    }

    private func localURLString(for server: HTTPServer) -> String {
        "http://localhost:\(server.port)"
    }

    private func accessModeSymbol(for server: HTTPServer) -> String {
        if server.exposeToLAN {
            return "↔"
        }
        return "⌂"
    }

    private func accessModeTitle(for server: HTTPServer) -> String {
        if server.exposeToLAN {
            return "Access: ↔ + ⌂"
        }
        return "Access: ⌂"
    }

    private func lanURLString(for server: HTTPServer) -> String? {
        guard server.exposeToLAN, let address = localNetworkAddresses().first else {
            return nil
        }
        return "http://\(address):\(server.port)"
    }

    private func localNetworkAddresses() -> [String] {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddress = ifaddrPointer else {
            return []
        }
        defer { freeifaddrs(ifaddrPointer) }

        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                continue
            }

            let address = String(cString: hostname)
            if !address.hasPrefix("169.254.") {
                addresses.insert(address)
            }
        }

        return addresses.sorted()
    }

    private func showRestoredLANWarning(for servers: [HTTPServer]) {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }

        let alert = NSAlert()
        alert.messageText = "Restored LAN-accessible servers"
        alert.informativeText = "\(servers.count) restored server(s) are reachable from your local network."
        alert.addButton(withTitle: "Stop LAN Servers")
        alert.addButton(withTitle: "Keep Running")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            serverManager.stopServers(servers)
            rebuildMenuItems()
        }
    }

    @objc private func openURLString(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyURLString(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        showCopyConfirmation()
    }

    @objc private func stopServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? HTTPServer else { return }
        serverManager.stopServer(server)
        rebuildMenuItems()
    }

    private func snapshotServers() -> [HTTPServer] {
        serverManager.snapshotServers()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showCopyConfirmation() {
        guard let button = statusItem.button else { return }
        let originalImage = button.image
        button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.statusItem.button?.image = originalImage
        }
    }

}
